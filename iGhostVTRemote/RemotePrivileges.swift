import Darwin
import Foundation

/// The user the helper runs as. The device daemon is root; the network side
/// has no use for that, so it becomes mobile — the user the sessions already
/// run as — before anything else happens. On the Mac the agent is already
/// the logged-in user and nothing changes.
enum RemotePrivileges {
    static func dropToSessionUser() -> Bool {
        guard getuid() == 0 || geteuid() == 0 else { return true }
        guard let entry = getpwnam("mobile") else { return false }
        let uid = entry.pointee.pw_uid
        let gid = entry.pointee.pw_gid
        var groups = [gid_t(gid)]
        guard setgroups(1, &groups) == 0,
              setgid(gid) == 0,
              setuid(uid) == 0,
              // Proof it took: a process that can become root again did not
              // drop anything.
              setuid(0) != 0
        else { return false }
        if let home = entry.pointee.pw_dir {
            setenv("HOME", home, 1)
        }
        setenv("USER", "mobile", 1)
        return true
    }
}
