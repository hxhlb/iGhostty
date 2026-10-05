import SwiftUI
import UIKit

/// The client's half of pairing, as setup pages: one field for the code
/// the other device shows — the pairing starts as the sixth digit lands. A
/// wrong code says so and clears the field for another try; the host counts
/// the tries.
///
/// Only a host Bonjour found on this network can be paired: a device that
/// cannot be discovered here is not offered at all.
struct RemotePairDeviceView: View {
    let host: DiscoveredRemoteHost
    /// In a popover: no navigation bar, and clicking away is Cancel.
    var isPopover = false
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var isPairing = false
    @State private var errorText: String?
    @State private var paired: PairedRemoteHost?
    @FocusState private var isCodeFocused: Bool

    var body: some View {
        container
            .onAppear {
                isCodeFocused = true
            }
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
                        if paired == nil {
                            Button("Cancel") {
                                dismiss()
                            }
                        }
                    }
                }
        }
        .navigationViewStyle(.stack)
    }

    /// Two steps: the code, then the outcome.
    @ViewBuilder
    private var page: some View {
        if let paired {
            SetupPage(
                symbol: "checkmark.circle.fill",
                tint: .green,
                title: String.localizedStringWithFormat(
                    NSLocalizedString("Paired with “%@”", comment: "%@ is the device that just paired"),
                    paired.displayName,
                ),
                message: String(localized: "You can open terminals on it from New Tab."),
            ) {
                EmptyView()
            } footer: {
                SetupPrimaryButton(title: String(localized: "Done")) {
                    dismiss()
                }
            }
        } else {
            SetupPage(
                symbol: "lock.iphone",
                title: String.localizedStringWithFormat(
                    NSLocalizedString("Pair with “%@”", comment: "Pairing sheet title; %@ is the other device"),
                    host.name,
                ),
                message: String.localizedStringWithFormat(
                    NSLocalizedString(
                        "Enter the code shown on “%@”.",
                        comment: "Under the pairing code field; %@ is the other device",
                    ),
                    host.name,
                ),
            ) {
                entry
            }
        }
    }

    private var entry: some View {
        VStack(spacing: DS.Padding.l) {
            TextField("000000", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(size: isPopover ? 28 : 34, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .focused($isCodeFocused)
                .padding(.vertical, DS.Padding.m)
                .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
                .disabled(isPairing)
                .onChange(of: code) { value in
                    let digits = String(value.filter(\.isNumber).prefix(RemoteAccess.pairingCodeLength))
                    if digits != value {
                        code = digits
                    } else if digits.count == RemoteAccess.pairingCodeLength {
                        pair()
                    }
                }
            Group {
                if isPairing {
                    ProgressView()
                } else if let errorText {
                    Text(errorText)
                        .foregroundColor(.red)
                }
            }
            .font(DS.Font.detail)
            .multilineTextAlignment(.center)
            .frame(minHeight: 36)
        }
    }

    private func pair() {
        guard code.count == RemoteAccess.pairingCodeLength, !isPairing else { return }
        isPairing = true
        errorText = nil
        Task {
            do {
                paired = try await RemotePairingClient.pair(with: host, code: code)
            } catch {
                errorText = error.localizedDescription
                code = ""
                isCodeFocused = true
            }
            isPairing = false
        }
    }
}
