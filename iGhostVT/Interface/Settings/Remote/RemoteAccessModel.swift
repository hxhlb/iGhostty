import Combine
import Foundation

/// This device's remote access, as the settings page shows it: the daemon's
/// answer to `remoteStatus`, asked again every few seconds while the page
/// is on screen — every second while a pairing window is open, so the
/// countdown, a failed attempt, and the device that paired show up as they
/// happen.
@MainActor
final class RemoteAccessModel: ObservableObject {
    @Published private(set) var status = RemoteAccessStatus()
    @Published private(set) var hasLoaded = false
    /// A switch flip on its way to the daemon; the toggle shows the
    /// requested state meanwhile.
    @Published private(set) var pendingEnabled: Bool?

    private var poll: Task<Void, Never>?

    var isEnabled: Bool {
        pendingEnabled ?? status.isEnabled
    }

    func appear() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval: UInt64 = (self?.status.pairingCode != nil) ? 1 : 3
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
            }
        }
    }

    func disappear() {
        poll?.cancel()
        poll = nil
    }

    func refresh() async {
        await apply(RemoteAccessControl.status())
    }

    func setEnabled(_ enabled: Bool) {
        pendingEnabled = enabled
        Task {
            let status = await RemoteAccessControl.setEnabled(enabled)
            pendingEnabled = nil
            apply(status)
            // The helper takes a moment to come up and answer for itself.
            try? await Task.sleep(nanoseconds: 700_000_000)
            await refresh()
        }
    }

    func beginPairing() async {
        let throughRelay = RelayConfigurationStore.current != nil
        await apply(RemoteAccessControl.beginPairing(throughRelay: throughRelay))
    }

    func endPairing() {
        Task { await apply(RemoteAccessControl.endPairing()) }
    }

    /// Names this device for the others — as a host, its advertisement;
    /// as a client, how it pairs and connects. Empty goes back to the
    /// device's own name. The helper is told now if it runs, else the next
    /// time it does (`apply`).
    func setName(_ name: String) {
        RemoteDeviceIdentity.chosenName = name
        UserDefaults.standard.set(true, forKey: Self.namePendingKey)
        if status.isEnabled {
            sendName()
        }
    }

    private static let namePendingKey = "Remote.hostNamePending"

    private func sendName() {
        UserDefaults.standard.set(false, forKey: Self.namePendingKey)
        Task { await apply(RemoteAccessControl.setHostName(RemoteDeviceIdentity.chosenName)) }
    }

    func revoke(_ device: RemoteAccessStatus.Device) {
        Task { await apply(RemoteAccessControl.revoke(deviceID: device.id)) }
    }

    private func apply(_ status: RemoteAccessStatus) {
        hasLoaded = true
        if status.isEnabled, status.state == .listening, UserDefaults.standard.bool(forKey: Self.namePendingKey) {
            sendName()
        }
        if status != self.status {
            self.status = status
        }
        RemoteHostDirectory.shared.noteOwnHostID(status.hostID)
        RemoteAccessActivity.note(status)
        RelayConfigurationSync.reconcile(with: status)
    }
}
