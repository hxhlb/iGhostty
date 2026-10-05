import Darwin
import Foundation

/// A name for this device that means something to its owner and tells it
/// apart from the others on the network.
///
/// The name the owner gave the device comes first. Without the entitlement
/// that unlocks it the system answers with the bare model — "iPad",
/// "iPhone" — and every device of a kind looks alike; then the model's
/// marketing name ("iPad Pro (11-inch)") stands in, and failing that the
/// model identifier ("iPad8,9").
enum DeviceNaming {
    static func meaningful(_ assigned: String?) -> String {
        if let assigned = assigned?.trimmingCharacters(in: .whitespacesAndNewlines),
           !assigned.isEmpty, !isGeneric(assigned)
        {
            return assigned
        }
        return marketingName() ?? modelIdentifier() ?? assigned ?? "iGhostVT"
    }

    /// What the system says in place of a name it will not give.
    static func isGeneric(_ name: String) -> Bool {
        ["iPad", "iPhone", "iPod touch", "iPod", "Mac", "Apple TV", "Apple Vision Pro"].contains(name)
    }

    /// "iPad Pro (11-inch)", from MobileGestalt; nil where there is none
    /// (the Mac) or it will not say.
    static func marketingName() -> String? {
        guard let handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY),
              let symbol = dlsym(handle, "MGCopyAnswer")
        else { return nil }
        typealias CopyAnswer = @convention(c) (CFString) -> Unmanaged<CFTypeRef>?
        let copyAnswer = unsafeBitCast(symbol, to: CopyAnswer.self)
        guard let name = copyAnswer("marketing-name" as CFString)?.takeRetainedValue() as? String,
              !name.isEmpty, !isGeneric(name)
        else { return nil }
        return name
    }

    /// "iPad8,9": the hardware model, always there.
    static func modelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else { return nil }
        let identifier = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return identifier.isEmpty ? nil : identifier
    }
}
