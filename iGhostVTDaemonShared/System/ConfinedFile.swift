import Darwin

/// Opens the daemon's own files without following anything another user
/// could have left on the way.
///
/// On the device both daemon programs run as root, and the log and the
/// session-id store sit in mobile's `Library/Logs`, a directory mobile owns.
/// A plain `open(O_CREAT)` there follows whatever mobile put at the name: a
/// symlink to `sudoers` had root truncate it, and a symlink to a root shell's
/// rc file had root append a log line to it — a line that quotes a refused
/// client's path, which can carry a newline and a command. So:
///
/// - The directory is walked one component at a time. A symlink is followed
///   only where it sits in a directory that only root (or this process's own
///   user) can change — `/var` → `private/var`, a rootless `/var/jb` — and
///   anywhere else the walk fails. A real directory is entered wherever it
///   is: whoever could put one there could only point the walk at a
///   directory they could already write.
/// - The file is opened `O_NOFOLLOW`, and kept only when it is a plain file
///   this process owns with no other name. Anything else at the name (a
///   hard link to someone else's file, a FIFO, a file mobile made) is
///   unlinked and the file created afresh, so a planted name costs the
///   history in it and nothing more.
///
/// On the Mac the daemon is the user's own agent and none of this is a
/// boundary, but the rules hold there just the same.
enum ConfinedFile {
    /// More than any real path takes; a loop of trusted links ends here.
    private static let maximumLinkHops = 16

    /// `path`'s directory and last component; nil for a path that is not
    /// absolute or names no file.
    static func split(_ path: String) -> (directory: String, name: String)? {
        guard path.hasPrefix("/"), let slash = path.lastIndex(of: "/") else { return nil }
        let name = String(path[path.index(after: slash)...])
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        let directory = String(path[..<slash])
        return (directory.isEmpty ? "/" : directory, name)
    }

    /// A descriptor on `path`, a directory reached as described above, with
    /// every missing component made (0755) on the way; -1 otherwise.
    static func openDirectory(_ path: String) -> Int32 {
        guard path.hasPrefix("/") else { return -1 }
        var components = path.split(separator: "/").map(String.init)
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        var index = 0
        var hops = 0
        while current >= 0, index < components.count {
            let name = components[index]
            if name == "." {
                index += 1
                continue
            }
            var info = stat()
            if fstatat(current, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                // Made here, or by a racer: either way it is opened below
                // without following, so a link slipped in meanwhile fails.
                guard errno == ENOENT, mkdirat(current, name, 0o755) == 0 || errno == EEXIST else {
                    close(current)
                    return -1
                }
            } else if info.st_mode & S_IFMT == S_IFLNK {
                hops += 1
                guard hops <= maximumLinkHops, isPrivate(current), let target = readLink(name, in: current) else {
                    close(current)
                    return -1
                }
                components = target.split(separator: "/").map(String.init) + components[(index + 1)...]
                index = 0
                if target.hasPrefix("/") {
                    close(current)
                    current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                }
                continue
            }
            let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current)
            current = next
            index += 1
        }
        return current
    }

    /// `name` in `directory`, opened with `flags` (`O_CREAT` creates it with
    /// `mode`) and returned only as a plain file this process owns with no
    /// other name; -1 otherwise. Without `O_CREAT`, a name that is anything
    /// else is left where it is.
    static func open(_ name: String, in directory: Int32, flags: Int32, mode: mode_t = 0o644) -> Int32 {
        // O_NONBLOCK: a FIFO at the name must not hang the open. It changes
        // nothing for a plain file.
        let flags = flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        var descriptor = openat(directory, name, flags, mode)
        if descriptor >= 0, isOwnedPlainFile(descriptor) {
            return descriptor
        }
        let opened = descriptor >= 0
        if opened {
            close(descriptor)
        }
        // ELOOP is O_NOFOLLOW meeting a symlink, ENXIO a FIFO nobody reads;
        // anything else that failed the open is not ours to clear.
        guard flags & O_CREAT != 0, opened || errno == ELOOP || errno == ENXIO else { return -1 }
        guard unlinkat(directory, name, 0) == 0 else { return -1 }
        descriptor = openat(directory, name, flags | O_EXCL, mode)
        guard descriptor >= 0 else { return -1 }
        guard isOwnedPlainFile(descriptor) else {
            close(descriptor)
            return -1
        }
        return descriptor
    }

    /// `path`, by `openDirectory` and `open(_:in:flags:mode:)`.
    static func open(_ path: String, flags: Int32, mode: mode_t = 0o644) -> Int32 {
        guard let (directoryPath, name) = split(path) else { return -1 }
        let directory = openDirectory(directoryPath)
        guard directory >= 0 else { return -1 }
        defer { close(directory) }
        return open(name, in: directory, flags: flags, mode: mode)
    }

    /// Only root or this process's own user can add, remove, or rename an
    /// entry: what makes a symlink in it, or a file's presence, trustworthy.
    static func isPrivate(_ directory: Int32) -> Bool {
        var info = stat()
        guard fstat(directory, &info) == 0 else { return false }
        return (info.st_uid == 0 || info.st_uid == geteuid()) && info.st_mode & (S_IWGRP | S_IWOTH) == 0
    }

    private static func isOwnedPlainFile(_ descriptor: Int32) -> Bool {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 && info.st_uid == geteuid()
    }

    private static func readLink(_ name: String, in directory: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlinkat(directory, name, &buffer, buffer.count - 1)
        guard length > 0 else { return nil }
        buffer[length] = 0
        return String(cString: buffer)
    }
}
