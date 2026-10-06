//
//  ZmodemFileBridge.swift
//  iGhostVT
//

import UIKit
import UniformTypeIdentifiers

enum ZmodemFileBridge {
    static let stagingDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("zmodem", isDirectory: true)

    /// `onSaved` fires once per batch the user actually saved (name, count).
    static func makeReceiveWriter(onSaved: @escaping @Sendable (String, Int) -> Void) -> ZmodemFileWriter {
        ZmodemReceiveWriter(onSaved: onSaved)
    }

    @MainActor
    static func requestUploadSource(_ completion: @escaping @Sendable (ZmodemFileSource?) -> Void) {
        ZmodemPickerPresenter.presentOpen { urls in
            guard !urls.isEmpty else {
                completion(nil)
                return
            }
            completion(ZmodemUploadSource(urls: urls))
        }
    }
}

// MARK: - Download: receive into temp files, then export

private final class ZmodemReceiveWriter: ZmodemFileWriter, @unchecked Sendable {
    private var received: [URL] = []
    private var handle: FileHandle?
    private var currentURL: URL?
    private let onSaved: @Sendable (String, Int) -> Void

    init(onSaved: @escaping @Sendable (String, Int) -> Void) {
        self.onSaved = onSaved
    }

    deinit {
        try? handle?.close()
        for url in received {
            try? FileManager.default.removeItem(at: url)
        }
        if let currentURL {
            try? FileManager.default.removeItem(at: currentURL)
        }
    }

    func beginFile(name: String, size _: UInt64?) -> Bool {
        let directory = ZmodemFileBridge.stagingDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = Self.sanitize(name)
        let url = Self.uniqueURL(for: safe, in: directory)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return false }
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        self.handle = handle
        currentURL = url
        return true
    }

    func write(_ bytes: [UInt8]) {
        guard let handle else { return }
        handle.write(Data(bytes))
    }

    func finishFile() {
        try? handle?.close()
        handle = nil
        if let currentURL {
            received.append(currentURL)
        }
        currentURL = nil
    }

    func finish(completed: Bool) {
        try? handle?.close()
        handle = nil
        let urls = received
        received = []
        guard completed, !urls.isEmpty else {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
            if let currentURL {
                try? FileManager.default.removeItem(at: currentURL)
            }
            return
        }
        let onSaved = onSaved
        let firstName = urls.first?.lastPathComponent ?? ""
        let count = urls.count
        DispatchQueue.main.async {
            ZmodemPickerPresenter.presentExport(urls) { saved in
                for url in urls {
                    try? FileManager.default.removeItem(at: url)
                }
                if !saved.isEmpty {
                    onSaved(firstName, count)
                }
            }
        }
    }

    /// A received name is untrusted: keep only the last path component and
    /// drop anything that could escape the save location.
    private static func sanitize(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let cleaned = base.replacingOccurrences(of: "/", with: "_")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "received" : cleaned
    }

    private static func uniqueURL(for name: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 1
        repeat {
            let suffix = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = directory.appendingPathComponent(suffix)
            index += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }
}

// MARK: - Upload: read from the files the user picked

private final class ZmodemUploadSource: ZmodemFileSource, @unchecked Sendable {
    private var urls: [URL]
    private var index = 0
    private var handle: FileHandle?

    init(urls: [URL]) {
        self.urls = urls
    }

    deinit {
        try? handle?.close()
        for url in urls where url.path.contains(FileManager.default.temporaryDirectory.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func nextFile() -> ZmodemOutgoingFile? {
        try? handle?.close()
        handle = nil
        guard index < urls.count else { return nil }
        let url = urls[index]
        index += 1
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil
        let handle = try? FileHandle(forReadingFrom: url)
        self.handle = handle
        return ZmodemOutgoingFile(name: url.lastPathComponent, size: size ?? 0) { [weak self] offset, maxLength in
            guard let self, let handle = self.handle else { return [] }
            do {
                try handle.seek(toOffset: offset)
                let data = try handle.read(upToCount: maxLength) ?? Data()
                return [UInt8](data)
            } catch {
                return []
            }
        }
    }

    func finish(completed _: Bool) {
        try? handle?.close()
        handle = nil
        for url in urls where url.path.contains(FileManager.default.temporaryDirectory.path) {
            try? FileManager.default.removeItem(at: url)
        }
        urls = []
    }
}

// MARK: - Picker presentation

@MainActor
private enum ZmodemPickerPresenter {
    /// Coordinators are retained here for the life of a presentation; the
    /// picker holds only a weak delegate.
    private static var coordinators: [ZmodemPickerCoordinator] = []

    static func presentOpen(_ completion: @escaping ([URL]) -> Void) {
        guard let top = topViewController() else {
            completion([])
            return
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        present(picker, from: top, completion: completion)
    }

    static func presentExport(_ urls: [URL], completion: @escaping ([URL]) -> Void) {
        guard let top = topViewController() else {
            completion([])
            return
        }
        let picker = UIDocumentPickerViewController(forExporting: urls)
        present(picker, from: top, completion: completion)
    }

    private static func present(
        _ picker: UIDocumentPickerViewController,
        from top: UIViewController,
        completion: @escaping ([URL]) -> Void,
    ) {
        var coordinator: ZmodemPickerCoordinator!
        coordinator = ZmodemPickerCoordinator { urls in
            completion(urls)
            coordinators.removeAll { $0 === coordinator }
        }
        picker.delegate = coordinator
        coordinators.append(coordinator)
        if let popover = picker.popoverPresentationController, let view = top.view {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        top.present(picker, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let windowScene = active as? UIWindowScene else { return nil }
        let window = windowScene.keyWindow ?? windowScene.windows.first(where: \.isKeyWindow) ?? windowScene.windows.first
        guard var top = window?.rootViewController else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

private final class ZmodemPickerCoordinator: NSObject, UIDocumentPickerDelegate {
    private let completion: ([URL]) -> Void
    private var answered = false

    init(completion: @escaping ([URL]) -> Void) {
        self.completion = completion
    }

    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        answer(urls)
    }

    func documentPickerWasCancelled(_: UIDocumentPickerViewController) {
        answer([])
    }

    private func answer(_ urls: [URL]) {
        guard !answered else { return }
        answered = true
        completion(urls)
    }
}
