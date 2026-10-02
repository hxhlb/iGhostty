//
//  BodyTrace.swift
//  iGhostVT
//

import Foundation

#if DEBUG
    /// Debug builds only: how often the views that carry a tab's menus
    /// re-evaluate their bodies, summed and logged once a second while any
    /// do. A menu's content re-evaluated while it is open is rebuilt by
    /// UIKit — it flickers and drops taps — so these should stay silent
    /// while a terminal prints; a line here during a flood of output is the
    /// regression `TabAttributes` exists to prevent.
    @MainActor
    enum BodyTrace {
        private static var counts: [String: Int] = [:]
        private static var isFlushScheduled = false

        static func note(_ view: String) {
            counts[view, default: 0] += 1
            guard !isFlushScheduled else { return }
            isFlushScheduled = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let summary = counts.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " ")
                counts = [:]
                isFlushScheduled = false
                AppLog.verbose(.tabs, "menu host bodies in the last second: \(summary)")
            }
        }
    }
#endif
