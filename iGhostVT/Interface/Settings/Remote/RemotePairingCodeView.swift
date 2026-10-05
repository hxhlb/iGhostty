import Combine
import SwiftUI
import UIKit

/// The host's half of pairing, as setup pages: the code and the time
/// left. Closing the sheet closes the window. When a
/// device pairs the sheet says so; when the code runs out (two minutes, or
/// three wrong tries) it offers a new one.
struct RemotePairingCodeView: View {
    @ObservedObject var model: RemoteAccessModel
    /// In a popover: no navigation bar, and clicking away is Cancel.
    var isPopover = false
    @Environment(\.dismiss) private var dismiss

    /// When the current code was issued: a device paired since is the one
    /// that just did — one pairing again keeps its id, so the list alone
    /// cannot tell.
    @State private var issuedAt = Date()
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        container
            .onAppear {
                issuedAt = Date()
                model.appear()
            }
            .onDisappear {
                if model.status.pairingCode != nil {
                    model.endPairing()
                }
            }
            .onReceive(clock) { now = $0 }
    }

    @ViewBuilder
    private var container: some View {
        if isPopover {
            page.environment(\.setupPageIsCompact, true)
        } else {
            sheet
        }
    }

    private var sheet: some View {
        NavigationView {
            page
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if model.status.pairingCode != nil, newlyPaired == nil {
                            Button("Cancel") {
                                dismiss()
                            }
                        }
                    }
                }
        }
        .navigationViewStyle(.stack)
    }

    /// One step per state: the code, the device that paired, or a code
    /// that ran out.
    @ViewBuilder
    private var page: some View {
        if let paired = newlyPaired {
            SetupPage(
                symbol: "checkmark.circle.fill",
                tint: .green,
                title: String.localizedStringWithFormat(
                    NSLocalizedString("Paired with “%@”", comment: "%@ is the device that just paired"),
                    paired.name,
                ),
                message: String(localized: "It can open terminals on this device now."),
            ) {
                EmptyView()
            } footer: {
                SetupPrimaryButton(title: String(localized: "Done")) {
                    dismiss()
                }
            }
        } else if let code = model.status.pairingCode {
            SetupPage(
                symbol: "lock.iphone",
                title: String(localized: "Pair New Device (title)"),
                message: String(localized: "Enter this code on the other device."),
            ) {
                codeView(code)
            }
        } else {
            SetupPage(
                symbol: "clock",
                tint: .secondary,
                title: String(localized: "Code Expired"),
                message: String(localized: "A code lasts two minutes and three tries."),
            ) {
                EmptyView()
            } footer: {
                SetupPrimaryButton(title: String(localized: "Get a New Code")) {
                    Task {
                        issuedAt = Date()
                        await model.beginPairing()
                    }
                }
            }
        }
    }

    private func codeView(_ code: String) -> some View {
        VStack(spacing: DS.Padding.l) {
            Text(spaced(code))
                .font(.system(size: isPopover ? 32 : 44, weight: .semibold, design: .monospaced))
                .padding(.vertical, DS.Padding.m)
                .frame(maxWidth: .infinity)
                .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
                .accessibilityLabel(code.map(String.init).joined(separator: " "))
            Text(statusLine)
                .font(DS.Font.detail)
                .foregroundColor(model.status.failedAttempts.isEmpty ? .secondary : .orange)
                .multilineTextAlignment(.center)
        }
    }

    /// The time left, and the last wrong try when there was one.
    private var statusLine: String {
        let seconds = max(0, Int((model.status.pairingExpiresAt ?? now).timeIntervalSince(now)))
        let remaining = String.localizedStringWithFormat(
            NSLocalizedString("Expires in %lld:%02lld", comment: "Time left on a pairing code, minutes:seconds"),
            seconds / 60,
            seconds % 60,
        )
        guard let last = model.status.failedAttempts.last else { return remaining }
        let wrong = String.localizedStringWithFormat(
            NSLocalizedString(
                "Wrong code from %1$@ (%2$lld of %3$lld tries)",
                comment: "A failed pairing try; %1$@ is the network address, then tries used and allowed",
            ),
            last.address,
            model.status.failedAttempts.count,
            RemoteAccess.pairingAttemptLimit,
        )
        return wrong + "\n" + remaining
    }

    private var newlyPaired: RemoteAccessStatus.Device? {
        // Whole seconds on the wire; a second's slack either way.
        model.status.devices
            .filter { $0.pairedAt.timeIntervalSince(issuedAt) > -1 }
            .max { $0.pairedAt < $1.pairedAt }
    }

    private func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return String(code.prefix(3)) + " " + String(code.suffix(3))
    }
}
