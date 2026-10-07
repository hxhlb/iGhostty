import Foundation

/// How a version mismatch between two devices is put into words: which
/// device runs what, and that both have to run the same.
enum RemoteVersionText {
    /// `theirs` empty: a device older than the rule, which does not say.
    /// `name` nil: "the other device".
    static func mismatch(theirs: String, name: String?) -> String {
        let ours = RemoteAccess.appVersion
        switch (theirs.isEmpty, name) {
        case let (true, name?):
            return String.localizedStringWithFormat(
                NSLocalizedString(
                    "“%1$@” runs an older version of iGhostVT, and this device runs %2$@. Update both to the same version to connect.",
                    comment: "%1$@ is the other device, %2$@ this device's version",
                ),
                name,
                ours,
            )
        case (true, nil):
            return String.localizedStringWithFormat(
                NSLocalizedString(
                    "The other device runs an older version of iGhostVT, and this device runs %@. Update both to the same version to connect.",
                    comment: "%@ is this device's version",
                ),
                ours,
            )
        case let (false, name?):
            return String.localizedStringWithFormat(
                NSLocalizedString(
                    "“%1$@” runs iGhostVT %2$@, and this device runs %3$@. Update both to the same version to connect.",
                    comment: "%1$@ is the other device, %2$@ its version, %3$@ this device's version",
                ),
                name,
                theirs,
                ours,
            )
        case (false, nil):
            return String.localizedStringWithFormat(
                NSLocalizedString(
                    "The other device runs iGhostVT %1$@, and this device runs %2$@. Update both to the same version to connect.",
                    comment: "%1$@ is the other device's version, %2$@ this device's",
                ),
                theirs,
                ours,
            )
        }
    }

    /// The short form a list row shows under a device that cannot connect.
    static func needsUpdate(theirs: String) -> String {
        if theirs.isEmpty {
            return String(localized: "Needs update: older version")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString(
                "Needs update: %1$@ there, %2$@ here",
                comment: "Under a device whose iGhostVT differs; %1$@ its version, %2$@ this device's",
            ),
            theirs,
            RemoteAccess.appVersion,
        )
    }
}
