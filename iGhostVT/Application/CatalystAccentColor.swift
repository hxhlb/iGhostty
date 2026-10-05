//
//  CatalystAccentColor.swift
//  iGhostVT
//

import Foundation

#if targetEnvironment(macCatalyst)
    import ObjectiveC

    /// The accent preference's AppKit half. What AppKit draws itself — the
    /// settings window's selected toolbar pane, menus, focus rings, the
    /// input method's candidate highlight — never asks UIKit for a tint; it
    /// asks `+[NSColor controlAccentColor]`, which under Multicolor answers
    /// the app's own accent (`NSAccentColorName`). `install()` puts a
    /// wrapper on that class method that answers the chosen colour instead,
    /// as AppKit's own dynamic system colour, so it still follows light and
    /// dark; with Multicolor it calls straight through.
    ///
    /// AppKit is reached through the ObjC runtime, as in
    /// `CatalystWindowChrome`: a class or selector that no longer exists
    /// leaves AppKit's own accent in place.
    enum CatalystAccentColor {
        /// The AppKit colour selector for the current choice; nil is no
        /// override. AppKit asks from whatever thread it draws on.
        private nonisolated(unsafe) static var override: Selector?
        private static let lock = NSLock()

        static func install() {
            guard let colorClass = NSClassFromString("NSColor"),
                  let metaclass = object_getClass(colorClass)
            else { return }
            let selector = sel_registerName("controlAccentColor")
            guard let method = class_getClassMethod(colorClass, selector) else { return }
            let original = method_getImplementation(method)
            typealias Original = @convention(c) (AnyObject, Selector) -> AnyObject
            let block: @convention(block) (AnyObject) -> AnyObject = { target in
                lock.lock()
                let chosen = override
                lock.unlock()
                if let chosen,
                   let color = (colorClass as AnyObject).perform(chosen)?.takeUnretainedValue()
                {
                    return color
                }
                return unsafeBitCast(original, to: Original.self)(target, selector)
            }
            class_replaceMethod(
                metaclass,
                selector,
                imp_implementationWithBlock(block),
                method_getTypeEncoding(method),
            )
            update(AccentColorPreference.current)
        }

        /// Swaps the colour AppKit answers and has every AppKit view redraw
        /// with it, as a change in System Settings would.
        static func update(_ preference: AccentColorPreference) {
            lock.lock()
            override = preference.appKitSelector.map { sel_registerName($0) }
            lock.unlock()
            NotificationCenter.default.post(
                name: Notification.Name("NSSystemColorsDidChangeNotification"),
                object: nil,
            )
        }
    }

    private extension AccentColorPreference {
        /// The `NSColor` class method for the choice: AppKit's own system
        /// colours, the ones System Settings' accents are.
        var appKitSelector: String? {
            switch self {
            case .multicolor: nil
            case .blue: "systemBlueColor"
            case .purple: "systemPurpleColor"
            case .pink: "systemPinkColor"
            case .red: "systemRedColor"
            case .orange: "systemOrangeColor"
            case .yellow: "systemYellowColor"
            case .green: "systemGreenColor"
            case .graphite: "systemGrayColor"
            }
        }
    }
#endif
