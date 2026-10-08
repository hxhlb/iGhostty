//
//  AppEdition.swift
//  iGhostVT
//

/// Which app this build is. iGhostVT talks to a daemon on its own device.
/// Ghost Remote (the `GhostRemote` target, compiled with `GHOST_REMOTE`)
/// runs sandboxed on a device without custom firmware: there is no daemon
/// to reach, so every tab is a paired device's terminal and every way to a
/// local daemon is closed. Both apps compile the same sources; this is the
/// one switch between them.
enum AppEdition {
    #if GHOST_REMOTE
        static let isRemoteOnly = true
        static let displayName = "Ghost Remote"
    #else
        static let isRemoteOnly = false
        static let displayName = "iGhostVT"
    #endif
}
