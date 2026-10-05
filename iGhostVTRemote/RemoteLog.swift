import Foundation
import os

/// The helper's log lines. It runs as mobile and cannot append to the
/// daemon's log, which root created, so each line travels to the proxy as
/// a management event and lands there (`RemoteSupervisor`) — one file for
/// the log viewer, as before. The unified log gets a copy.
enum RemoteLog {
    private static let logger = Logger(subsystem: "wiki.qaq.ighostvtd", category: "remote")
    /// Set by `RemoteService` once the management socket is up; lines
    /// before that go to the unified log only.
    nonisolated(unsafe) static var sink: ((String) -> Void)?

    static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        sink?(message)
    }
}
