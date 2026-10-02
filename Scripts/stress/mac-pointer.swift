#!/usr/bin/env swift
//
//  mac-pointer.swift
//  iGhostVT
//
//  Drives the Mac app with synthetic pointer and key events, for
//  reproducing tab-strip, sidebar and drag bugs and for the stress
//  scenarios. Run it in the logged-in user's GUI session of a test
//  machine — CGEvent posting needs Accessibility, `windows` needs Screen
//  Recording for titles — never on a Mac whose terminals you depend on.
//
//    swift mac-pointer.swift windows
//    swift mac-pointer.swift click X Y [--right] [--count n]
//    swift mac-pointer.swift drag X1 Y1 X2 Y2 [--hold ms] [--steps n] [--step-ms ms]
//    swift mac-pointer.swift scroll X Y DY [--dx n]
//    swift mac-pointer.swift move X Y
//    swift mac-pointer.swift key <chord>       e.g. cmd+t, cmd+shift+], ctrl+tab, return
//    swift mac-pointer.swift type <text>
//
//  Coordinates are global screen points, top-left origin — the same space
//  `windows` prints its frames in, so a point inside a window is its
//  frame's origin plus an offset.
//

import AppKit
import CoreGraphics
import Foundation

let source = CGEventSource(stateID: .hidSystemState)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mac-pointer: \(message)\n".utf8))
    exit(64)
}

func pause(ms: Int) {
    usleep(useconds_t(max(ms, 0)) * 1000)
}

func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left, clickState: Int64 = 1) {
    guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
        fail("could not create a \(type.rawValue) event")
    }
    event.setIntegerValueField(.mouseEventClickState, value: clickState)
    // Explicitly unmodified: the HID-state source otherwise inherits flags a
    // previous `key` chord left behind, and a stray ⌃ turns a click into a
    // context-menu click and a drag into nothing at all.
    event.flags = []
    event.post(tap: .cghidEventTap)
}

/// The value after `flag`, or the default when the flag is absent.
func option(_ flag: String, in arguments: [String], default value: Int) -> Int {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return value }
    guard let parsed = Int(arguments[index + 1]) else { fail("\(flag) wants an integer") }
    return parsed
}

func number(_ text: String) -> CGFloat {
    guard let value = Double(text) else { fail("not a number: \(text)") }
    return CGFloat(value)
}

func windows() {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for info in list {
        let owner = info[kCGWindowOwnerName as String] as? String ?? ""
        guard owner.localizedCaseInsensitiveContains("ighostvt") else { continue }
        let id = info[kCGWindowNumber as String] as? Int ?? 0
        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        let name = info[kCGWindowName as String] as? String ?? ""
        let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let frame = [bounds["X"], bounds["Y"], bounds["Width"], bounds["Height"]].map { Int($0 ?? 0) }
        print("\(id)\tlayer=\(layer)\tframe=\(frame[0]),\(frame[1]),\(frame[2]),\(frame[3])\t\(owner)\t\(name)")
    }
}

func click(_ point: CGPoint, right: Bool, count: Int) {
    let button: CGMouseButton = right ? .right : .left
    post(.mouseMoved, at: point)
    pause(ms: 60)
    for index in 1 ... max(count, 1) {
        post(right ? .rightMouseDown : .leftMouseDown, at: point, button: button, clickState: Int64(index))
        pause(ms: 40)
        post(right ? .rightMouseUp : .leftMouseUp, at: point, button: button, clickState: Int64(index))
        pause(ms: 60)
    }
}

/// Press, hold still long enough for a lift to register, travel in even
/// steps, settle, release. UIKit's drag on Catalyst starts from movement
/// after the press, and a SwiftUI long-press lift wants the hold.
func drag(from start: CGPoint, to end: CGPoint, holdMS: Int, steps: Int, stepMS: Int) {
    post(.mouseMoved, at: start)
    pause(ms: 80)
    post(.leftMouseDown, at: start)
    pause(ms: holdMS)
    let count = max(steps, 1)
    for step in 1 ... count {
        let t = CGFloat(step) / CGFloat(count)
        let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        post(.leftMouseDragged, at: point)
        pause(ms: stepMS)
    }
    pause(ms: 300)
    post(.leftMouseDragged, at: end)
    pause(ms: 200)
    post(.leftMouseUp, at: end)
}

func scroll(at point: CGPoint, dy: Int32, dx: Int32) {
    post(.mouseMoved, at: point)
    pause(ms: 60)
    guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else {
        fail("could not create a scroll event")
    }
    event.location = point
    event.post(tap: .cghidEventTap)
}

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
    "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
    "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36,
    "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
    "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "escape": 53,
    "left": 123, "right": 124, "down": 125, "up": 126,
]

let modifierFlags: [String: CGEventFlags] = [
    "cmd": .maskCommand, "shift": .maskShift, "ctrl": .maskControl, "opt": .maskAlternate, "alt": .maskAlternate,
]

func key(_ chord: String) {
    var parts = chord.lowercased().split(separator: "+").map(String.init)
    // "cmd++" splits into an empty tail: the plus key, which is "=".
    if chord.hasSuffix("++") { parts.removeAll { $0.isEmpty }; parts.append("=") }
    guard let name = parts.popLast(), let code = keyCodes[name] else { fail("unknown key in \(chord)") }
    var flags: CGEventFlags = []
    for part in parts {
        guard let flag = modifierFlags[part] else { fail("unknown modifier \(part)") }
        flags.insert(flag)
    }
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { fail("no key event") }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        pause(ms: 30)
    }
}

func type(_ text: String) {
    for character in text.utf16 {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { fail("no key event") }
            var unit = character
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            event.post(tap: .cghidEventTap)
            pause(ms: 15)
        }
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail("usage: windows | click | drag | scroll | move | key | type") }
arguments.removeFirst()

if command != "windows", command != "type", command != "key", !AXIsProcessTrusted() {
    FileHandle.standardError.write(Data("mac-pointer: this process is not trusted for Accessibility; events may be dropped\n".utf8))
}

switch command {
case "windows":
    windows()
case "click":
    guard arguments.count >= 2 else { fail("click X Y") }
    click(CGPoint(x: number(arguments[0]), y: number(arguments[1])), right: arguments.contains("--right"), count: option("--count", in: arguments, default: 1))
case "drag":
    guard arguments.count >= 4 else { fail("drag X1 Y1 X2 Y2") }
    drag(
        from: CGPoint(x: number(arguments[0]), y: number(arguments[1])),
        to: CGPoint(x: number(arguments[2]), y: number(arguments[3])),
        holdMS: option("--hold", in: arguments, default: 600),
        steps: option("--steps", in: arguments, default: 20),
        stepMS: option("--step-ms", in: arguments, default: 30),
    )
case "scroll":
    guard arguments.count >= 3 else { fail("scroll X Y DY") }
    scroll(at: CGPoint(x: number(arguments[0]), y: number(arguments[1])), dy: Int32(number(arguments[2])), dx: Int32(option("--dx", in: arguments, default: 0)))
case "move":
    guard arguments.count >= 2 else { fail("move X Y") }
    post(.mouseMoved, at: CGPoint(x: number(arguments[0]), y: number(arguments[1])))
case "key":
    guard let chord = arguments.first else { fail("key <chord>") }
    key(chord)
case "type":
    type(arguments.joined(separator: " "))
default:
    fail("unknown command \(command)")
}
