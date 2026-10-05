//
//  CatalystAccentColor.swift
//  iGhostVT
//

import Foundation

#if targetEnvironment(macCatalyst)
    import ObjectiveC

    /// The accent preference's AppKit half. What AppKit draws itself — a
    /// menu's highlighted item, focus rings — never asks UIKit for a tint;
    /// it asks `+[NSColor controlAccentColor]`, which under Multicolor
    /// answers the app's own accent (`NSAccentColorName`). `install()` puts a
    /// wrapper on that class method that answers the chosen colour instead,
    /// as AppKit's own dynamic system colour, so it still follows light and
    /// dark; with Multicolor it calls straight through.
    ///
    /// Not everything AppKit tints asks that method: the settings window's
    /// selected toolbar pane reads the application's own accent
    /// (`-[NSApplication _effectiveAccentColor]`, which is `_accentColor`
    /// when one is set and the asset catalog's otherwise), so `update` sets
    /// that too (`_setAccentColor:`, nil for the app's own).
    ///
    /// AppKit is reached through the ObjC runtime, as in
    /// `CatalystWindowChrome`: a class or selector that no longer exists
    /// leaves AppKit's own accent in place.
    enum CatalystAccentColor {
        /// The AppKit colour selector for the current choice; nil is no
        /// override. AppKit asks from whatever thread it draws on.
        private nonisolated(unsafe) static var override: Selector?
        private static let lock = NSLock()
        /// What `NSApp` was last given; nil until the app is up.
        /// Read and written on the main thread only, where `update` is called
        /// once the app is up.
        private nonisolated(unsafe) static var applicationAccent: Selector??

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
            update(AccentColorPreference.current, includingApplication: false)
        }

        /// Swaps the colour AppKit answers and has every AppKit view redraw
        /// with it, as a change in System Settings would.
        /// Every hosting root calls this as it appears, so only an actual
        /// change tells AppKit to redraw.
        ///
        /// The application's own accent is set only once the app is up
        /// (`install` runs before `UIApplicationMain`, and asking for
        /// `NSApp` there would make one too early), so the first hosting
        /// root to appear is what applies a choice made in an earlier run.
        static func update(_ preference: AccentColorPreference, includingApplication: Bool = true) {
            let chosen = preference.appKitSelector.map { sel_registerName($0) }
            lock.lock()
            let changed = chosen != override
            override = chosen
            lock.unlock()
            if includingApplication, applicationAccent != .some(chosen) {
                applicationAccent = .some(chosen)
                setApplicationAccent(chosen)
            }
            guard changed else { return }
            NotificationCenter.default.post(
                name: Notification.Name("NSSystemColorsDidChangeNotification"),
                object: nil,
            )
        }
    }

    extension CatalystAccentColor {
        /// `NSApp._setAccentColor:` with the chosen AppKit colour, or nil
        /// for the app's own; a selector that is gone is left alone.
        fileprivate static func setApplicationAccent(_ chosen: Selector?) {
            guard let applicationClass = NSClassFromString("NSApplication") as? NSObject.Type,
                  let colorClass = NSClassFromString("NSColor") as? NSObject.Type,
                  let application = applicationClass.value(forKey: "sharedApplication") as? NSObject
            else { return }
            let setter = sel_registerName("_setAccentColor:")
            guard application.responds(to: setter) else { return }
            let color = chosen.flatMap { colorClass.perform($0)?.takeUnretainedValue() }
            application.perform(setter, with: color)
        }
    }

    private extension AccentColorPreference {
        /// The `NSColor` class method for the choice: AppKit's own system
        /// colours, the ones System Settings' accents are.
        var appKitSelector: String? {
            switch self {
            case .appDefault: nil
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
