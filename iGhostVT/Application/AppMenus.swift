//
//  AppMenus.swift
//  iGhostVT
//

import UIKit

/// The actions the main menu dispatches, resolved through the responder
/// chain. `TerminalWindow` implements them for its own tabs, so a command
/// always lands in the window that has focus — the Mac's menu bar and the
/// iPad's hold-⌘ overlay both read this one list.
@MainActor
@objc protocol AppCommandResponder {
    func newTab(_ sender: Any?)
    func newWindow(_ sender: Any?)
    func closeTab(_ sender: Any?)
    func closeWindow(_ sender: Any?)
    func exportTabText(_ sender: Any?)
    func showSettings(_ sender: Any?)
    func toggleTabSidebar(_ sender: Any?)
    func toggleTabSwitcher(_ sender: Any?)
    func increaseFontSize(_ sender: Any?)
    func decreaseFontSize(_ sender: Any?)
    func resetFontSize(_ sender: Any?)
    func clearScreen(_ sender: Any?)
    func showNextTab(_ sender: Any?)
    func showPreviousTab(_ sender: Any?)
    /// `sender` is a `UICommand` whose `propertyList` is the tab index;
    /// `AppMenus.lastTabIndex` means the last tab, whatever the count.
    func selectTab(_ sender: Any?)
    func toggleTabLock(_ sender: Any?)
    func toggleKeyboardLock(_ sender: Any?)
}

/// The app's menu bar, following the platform's own bindings: Terminal.app
/// and Safari for tabs and windows, Ghostty for the terminal itself.
///
/// Where two conventions coexist, both keys work and the menu shows the one
/// Apple's apps print — ⌘T for New Tab with ⌘N as a hidden alias, ⌃Tab for
/// Next Tab with ⇧⌘] hidden, ⌃⌘S (the AppKit standard) for the sidebar with
/// Safari's ⇧⌘L hidden. A hidden command still fires; it is only kept out of
/// the menu and the overlay so each action reads with a single key. Close
/// Tab has no ⌘⌫ alias: in a terminal that key deletes to the line start.
///
/// The titles and chords live in `KeyShortcuts`, the one list this menu,
/// the terminal view's interception, and Settings ▸ Shortcuts all read. A
/// command the user switched off is built as a plain `UICommand`: still
/// in the menu, no key beside it, so the menu bar and the hold-⌘ overlay
/// claim nothing the terminal now gets.
///
/// Main-actor isolated, as `UIMenuBuilder` and every element it takes are;
/// the one entry point is `buildMenu(with:)`, which already runs there.
@MainActor
enum AppMenus {
    /// `propertyList` of the Go to Tab command that means "the last tab".
    /// Nonisolated: a plain constant a validator may read from anywhere.
    nonisolated static let lastTabIndex = -1

    static func install(into builder: UIMenuBuilder) {
        installFileMenu(into: builder)
        installSettings(into: builder)
        installViewMenu(into: builder)
        installWindowMenu(into: builder)
    }

    // MARK: - File

    /// The system File menu's New (⌘N) opens a window and its Close (⌘W)
    /// closes one; in a tabbed terminal both keys belong to the tab.
    private static func installFileMenu(into builder: UIMenuBuilder) {
        for identifier in [UIMenu.Identifier.newScene, .close] where builder.menu(for: identifier) != nil {
            builder.remove(menu: identifier)
        }

        let newGroup = UIMenu(
            title: "",
            identifier: UIMenu.Identifier("wiki.qaq.iGhostVT.file.new"),
            options: .displayInline,
            children: [
                command(#selector(AppCommandResponder.newTab(_:))),
                hidden(#selector(AppCommandResponder.newTab(_:))),
                remoteTabMenu(),
                command(#selector(AppCommandResponder.newWindow(_:))),
            ].compactMap(\.self),
        )
        let closeGroup = UIMenu(
            title: "",
            identifier: UIMenu.Identifier("wiki.qaq.iGhostVT.file.close"),
            options: .displayInline,
            children: [
                command(#selector(AppCommandResponder.closeTab(_:))),
                command(#selector(AppCommandResponder.closeWindow(_:))),
            ],
        )
        let exportGroup = UIMenu(
            title: "",
            identifier: UIMenu.Identifier("wiki.qaq.iGhostVT.file.export"),
            options: .displayInline,
            children: [
                command(#selector(AppCommandResponder.exportTabText(_:))),
            ],
        )
        builder.insertChild(newGroup, atStartOfMenu: .file)
        builder.insertSibling(closeGroup, afterMenu: newGroup.identifier)
        builder.insertSibling(exportGroup, afterMenu: closeGroup.identifier)
    }

    /// New Tab on ▸ the paired devices on the network (remote access) ▸ a
    /// fresh shell, one in a directory a tab here was in on that device, or
    /// one of the terminals the device has open. Fewer than three devices
    /// are listed inline under their names, more each get a submenu. With
    /// none nearby it says so and points at the settings that pair one.
    ///
    /// Worked out each time the menu opens (`uncached`), from what the
    /// directory and the catalog know — and the Mac's menu bar keeps a
    /// deferred element's first answer whatever it was told, so
    /// `RemoteSessionCatalog` also rebuilds the main menu whenever that
    /// knowledge changes (`setNeedsRebuild`). Without that the first
    /// opening, made before Bonjour had found anything, said No Paired
    /// Devices for the rest of the run.
    private static func remoteTabMenu() -> UIMenu {
        let devices = UIDeferredMenuElement.uncached { completion in
            RemoteHostDirectory.shared.start()
            completion(remoteTabMenuItems())
            Task { @MainActor in
                // Fresh lists for the next opening; the rebuild that
                // follows a change brings them in.
                await RemoteSessionCatalog.shared.refresh()
            }
        }
        return UIMenu(
            title: String(localized: "New Tab on Device"),
            image: UIImage(systemName: "network"),
            identifier: UIMenu.Identifier("wiki.qaq.iGhostVT.file.newRemote"),
            children: [devices],
        )
    }

    private static func remoteTabMenuItems() -> [UIMenuElement] {
        let hosts = RemoteHostDirectory.shared.reachablePaired
        guard !hosts.isEmpty else {
            return [
                UIAction(
                    title: String(localized: "No Paired Devices Nearby"),
                    attributes: .disabled,
                ) { _ in },
                UIAction(
                    title: String(localized: "Remote Access Settings…"),
                    image: UIImage(systemName: "gearshape"),
                ) { _ in
                    UIApplication.shared.sendAction(
                        #selector(AppCommandResponder.showSettings(_:)),
                        to: nil,
                        from: nil,
                        for: nil,
                    )
                },
            ]
        }
        let sessions = RemoteSessionCatalog.shared.sessions
        let flattened = hosts.count < NewTabDirectoryChoices.remoteSubmenuThreshold
        return hosts.map { host in
            let fresh = UIAction(
                title: String(localized: "New Terminal", comment: "Menu item: a fresh shell on another device"),
                image: UIImage(systemName: "plus"),
            ) { _ in
                Task { @MainActor in
                    _ = try? await ShortcutBridge.openRemoteTab(hostID: host.id)
                }
            }
            let recents = RecentDirectoryStore.shared.menuDirectories(onHost: host.id).map { directory in
                UIAction(title: directory.label, image: UIImage(systemName: "clock")) { _ in
                    Task { @MainActor in
                        _ = try? await ShortcutBridge.openRemoteTab(hostID: host.id, directory: directory)
                    }
                }
            }
            let open = (sessions[host.id] ?? []).map { session in
                UIAction(
                    title: session.label.isEmpty ? String(localized: "Terminal") : session.label,
                    image: UIImage(systemName: "terminal"),
                ) { _ in
                    Task { @MainActor in
                        _ = try? await ShortcutBridge.openRemoteTab(hostID: host.id, attachingTo: session.id)
                    }
                }
            }
            if flattened {
                return UIMenu(
                    title: host.displayName,
                    options: .displayInline,
                    children: [fresh] + recents + open,
                )
            }
            var children: [UIMenuElement] = [fresh]
            if !recents.isEmpty {
                children.append(UIMenu(title: String(localized: "Recent"), options: .displayInline, children: recents))
            }
            if !open.isEmpty {
                children.append(UIMenu(title: String(localized: "Open Terminals"), options: .displayInline, children: open))
            }
            return UIMenu(title: host.displayName, image: UIImage(systemName: "network"), children: children)
        }
    }

    // MARK: - Settings

    /// ⌘, in the application menu, where every Mac app keeps it.
    private static func installSettings(into builder: UIMenuBuilder) {
        let settings = UIMenu(
            title: "",
            identifier: UIMenu.Identifier("wiki.qaq.iGhostVT.settings"),
            options: .displayInline,
            children: [
                command(#selector(AppCommandResponder.showSettings(_:))),
            ],
        )
        if builder.menu(for: .preferences) != nil {
            builder.replace(menu: .preferences, with: settings)
        } else if builder.menu(for: .about) != nil {
            builder.insertSibling(settings, afterMenu: .about)
        } else {
            builder.insertChild(settings, atStartOfMenu: .application)
        }
    }

    // MARK: - View

    private static func installViewMenu(into builder: UIMenuBuilder) {
        // Catalyst's own Show Sidebar item targets a split view controller
        // this app does not have; ours takes its place and its key.
        if builder.menu(for: .sidebar) != nil {
            builder.remove(menu: .sidebar)
        }
        let chrome = UIMenu(
            title: "",
            identifier: UIMenu.Identifier("wiki.qaq.iGhostVT.view.chrome"),
            options: .displayInline,
            children: [
                // The title is rewritten by `validate(_:)` to say Show or Hide.
                command(#selector(AppCommandResponder.toggleTabSidebar(_:))),
                hidden(#selector(AppCommandResponder.toggleTabSidebar(_:))),
                command(#selector(AppCommandResponder.toggleTabSwitcher(_:))),
            ].compactMap(\.self),
        )
        let text = UIMenu(
            title: "",
            identifier: UIMenu.Identifier("wiki.qaq.iGhostVT.view.text"),
            options: .displayInline,
            children: [
                command(#selector(AppCommandResponder.increaseFontSize(_:))),
                hidden(#selector(AppCommandResponder.increaseFontSize(_:))),
                command(#selector(AppCommandResponder.decreaseFontSize(_:))),
                command(#selector(AppCommandResponder.resetFontSize(_:))),
            ].compactMap(\.self),
        )
        let screen = UIMenu(
            title: "",
            identifier: UIMenu.Identifier("wiki.qaq.iGhostVT.view.screen"),
            options: .displayInline,
            children: [
                command(#selector(AppCommandResponder.clearScreen(_:))),
            ],
        )
        builder.insertChild(chrome, atStartOfMenu: .view)
        builder.insertSibling(text, afterMenu: chrome.identifier)
        builder.insertSibling(screen, afterMenu: text.identifier)
    }

    // MARK: - Window

    private static func installWindowMenu(into builder: UIMenuBuilder) {
        var gotoChildren: [UIMenuElement] = (1 ... KeyShortcuts.numberedTabCount).map { number in
            command(#selector(AppCommandResponder.selectTab(_:)), propertyList: number - 1)
        }
        gotoChildren.append(command(#selector(AppCommandResponder.selectTab(_:)), propertyList: lastTabIndex))
        let navigation = UIMenu(
            title: "",
            identifier: UIMenu.Identifier("wiki.qaq.iGhostVT.window.tabs"),
            options: .displayInline,
            children: [
                command(#selector(AppCommandResponder.showPreviousTab(_:))),
                hidden(#selector(AppCommandResponder.showPreviousTab(_:))),
                command(#selector(AppCommandResponder.showNextTab(_:))),
                hidden(#selector(AppCommandResponder.showNextTab(_:))),
                UIMenu(
                    title: NSLocalizedString("Go to Tab", comment: "Menu: submenu listing tab positions"),
                    identifier: UIMenu.Identifier("wiki.qaq.iGhostVT.window.goto"),
                    children: gotoChildren,
                ),
            ].compactMap(\.self),
        )
        var lockChildren: [UIMenuElement] = [
            command(#selector(AppCommandResponder.toggleTabLock(_:))),
        ]
        // The keyboard lock is not offered on the Mac (`TabContextMenu`
        // has the reasoning); the menu item and its ⌥⌘K go with it.
        #if !targetEnvironment(macCatalyst)
            lockChildren.append(command(#selector(AppCommandResponder.toggleKeyboardLock(_:))))
        #endif
        let locks = UIMenu(
            title: "",
            identifier: UIMenu.Identifier("wiki.qaq.iGhostVT.window.locks"),
            options: .displayInline,
            children: lockChildren,
        )
        builder.insertChild(navigation, atStartOfMenu: .window)
        builder.insertSibling(locks, afterMenu: navigation.identifier)
    }

    // MARK: - Helpers

    /// The listed item for an action: its key command while its switch is
    /// on, a keyless `UICommand` while it is off.
    private static func command(_ action: Selector, propertyList: Int? = nil) -> UICommand {
        let shortcut = KeyShortcuts.shortcut(action, propertyList: propertyList)
        guard shortcut.isEnabled else {
            return UICommand(title: shortcut.title, action: action, propertyList: propertyList)
        }
        return UIKeyCommand(
            title: shortcut.title,
            action: action,
            input: shortcut.input,
            modifierFlags: shortcut.modifiers,
            propertyList: propertyList,
        )
    }

    /// An alias key: fires the same action, never listed — and nothing at
    /// all while its twin's switch is off.
    ///
    /// `UIMenuBuilder` rejects two commands with the same action unless a
    /// `propertyList` tells them apart — inserting the alias next to its
    /// listed twin otherwise throws at launch ("Inserted elements contain
    /// duplicates"). The value only has to differ from the twin's `nil`;
    /// `TerminalWindow` reads a `propertyList` as an `Int` tab index and
    /// ignores this string.
    private static func hidden(_ action: Selector) -> UIKeyCommand? {
        let shortcut = KeyShortcuts.alias(action)
        guard shortcut.isEnabled else { return nil }
        return UIKeyCommand(
            title: "",
            action: action,
            input: shortcut.input,
            modifierFlags: shortcut.modifiers,
            propertyList: "alias",
            attributes: .hidden,
        )
    }
}
