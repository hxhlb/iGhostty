//
//  MacRemotePane.swift
//  iGhostVT
//

import SwiftUI

#if targetEnvironment(macCatalyst)

    /// Settings ▸ Remote on the Mac: the same settings as the iPhone and
    /// iPad page (`RemoteAccessView`), read from the same model and
    /// directory, laid out as a Mac pane — a checkbox and a name field in
    /// the label column, then the devices in two tables with their buttons
    /// under them, the selected row's details beside the buttons.
    struct MacRemotePane: View {
        @StateObject private var model = RemoteAccessModel()
        @ObservedObject private var directory = RemoteHostDirectory.shared

        @State private var name = RemoteDeviceIdentity.chosenName ?? ""
        @State private var selectedAllowedID: String?
        @State private var selectedHostID: String?
        @State private var nickname = ""
        @State private var isShowingPairingCode = false
        @State private var pairingHost: DiscoveredRemoteHost?
        @State private var window: UIWindow?

        var body: some View {
            VStack(alignment: .leading, spacing: DS.Padding.l) {
                MacSettingsRow("Remote Access") {
                    MacCheckbox(String(localized: "Allow Remote Access"), isOn: Binding(
                        get: { model.isEnabled },
                        set: { model.setEnabled($0) },
                    ))
                    .disabled(!model.hasLoaded || model.status.isUnavailable)
                } details: {
                    // A problem takes the note's line rather than adding one.
                    if let problem = RemoteAccessView.problem(model) {
                        Text(problem)
                            .font(DS.Font.detail)
                            .foregroundColor(.red)
                            .lineLimit(1)
                    } else {
                        MacSettingsNote("Paired devices on this network can open terminals here.")
                    }
                }
                MacSettingsRow("Name") {
                    TextField(RemoteDeviceIdentity.systemName, text: $name)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .frame(maxWidth: 300)
                        .onSubmit(saveName)
                } details: {
                    MacSettingsNote(
                        "Your other devices see this device by this name. Leave it empty to use the name set on the device.",
                    )
                }
                Divider()
                // Both tables stay put whatever the switch says, so turning
                // it on or off moves nothing: off, the first is dimmed.
                allowedDevices
                    .disabled(!model.isEnabled)
                    .opacity(model.isEnabled ? 1 : 0.5)
                yourDevices
            }
            .padding(DS.Padding.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(WindowReader(window: $window))
            .onAppear {
                model.appear()
                directory.start()
            }
            .onDisappear {
                saveName()
                saveNickname()
                model.disappear()
            }
            .onChange(of: selectedHostID) { _ in
                nickname = selectedPaired?.nickname ?? ""
            }
            .sheet(isPresented: $isShowingPairingCode) {
                RemotePairingCodeView(model: model)
            }
            .sheet(item: $pairingHost) { host in
                RemotePairDeviceView(host: host)
            }
        }

        private func saveName() {
            guard name != (RemoteDeviceIdentity.chosenName ?? "") else { return }
            model.setName(name)
        }

        // MARK: - This Mac as a host

        /// The devices that may open terminals here, and pairing one more.
        private var allowedDevices: some View {
            VStack(alignment: .leading, spacing: DS.Padding.s) {
                Text("Allowed Devices")
                    .font(DS.Font.labelEmphasis)
                MacTableFrame {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.status.devices.enumerated()), id: \.element.id) { index, device in
                                MacDeviceRow(
                                    name: device.name,
                                    address: nil,
                                    detail: RemoteAccessView.lastSeenText(device),
                                    index: index,
                                    isSelected: device.id == selectedAllowedID,
                                ) {
                                    selectedAllowedID = device.id
                                }
                                .contextMenu {
                                    Button("Remove", role: .destructive) { model.revoke(device) }
                                }
                            }
                        }
                    }
                    .overlay {
                        if model.status.devices.isEmpty {
                            Text("Pair a device to let it open terminals here.")
                                .font(DS.Font.detail)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(height: Self.tableHeight)
                HStack(spacing: DS.Padding.s) {
                    Button("Pair New Device…") {
                        Task {
                            await model.beginPairing()
                            isShowingPairingCode = true
                        }
                    }
                    .disabled(model.status.state != .listening)
                    Button("Remove") {
                        if let device = model.status.devices.first(where: { $0.id == selectedAllowedID }) {
                            model.revoke(device)
                            selectedAllowedID = nil
                        }
                    }
                    .disabled(!model.status.devices.contains { $0.id == selectedAllowedID })
                    Spacer()
                }
                .buttonStyle(.bordered)
                .tint(Color(.label))
            }
        }

        /// One height for both tables, never the content's: rows coming
        /// and going scroll inside it.
        private static let tableHeight: CGFloat = 112

        // MARK: - The other devices

        /// The devices this Mac is paired with, then the ones nearby it
        /// could pair with.
        private var yourDevices: some View {
            let unpaired = directory.unpairedNearby
            return VStack(alignment: .leading, spacing: DS.Padding.s) {
                Text("Your Devices")
                    .font(DS.Font.labelEmphasis)
                MacTableFrame {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(directory.paired.enumerated()), id: \.element.id) { index, host in
                                MacDeviceRow(
                                    name: host.displayName,
                                    address: directory.address(of: host),
                                    detail: directory.isDiscovered(host.id) ? String(localized: "Nearby") : "",
                                    index: index,
                                    isSelected: host.id == selectedHostID,
                                ) {
                                    selectedHostID = host.id
                                }
                            }
                            ForEach(Array(unpaired.enumerated()), id: \.element.id) { offset, host in
                                MacDeviceRow(
                                    name: host.name,
                                    address: host.address,
                                    detail: "",
                                    index: directory.paired.count + offset,
                                    isSelected: host.id == selectedHostID,
                                ) {
                                    selectedHostID = host.id
                                }
                            }
                        }
                    }
                    .overlay {
                        if directory.paired.isEmpty, unpaired.isEmpty {
                            Text("Devices on this network with remote access on appear here.")
                                .font(DS.Font.detail)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(DS.Padding.m)
                        }
                    }
                }
                .frame(height: Self.tableHeight)
                HStack(spacing: DS.Padding.s) {
                    if let host = selectedPaired {
                        TextField(host.name, text: $nickname)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                            .frame(maxWidth: 220)
                            .onSubmit(saveNickname)
                            .accessibilityLabel("Name")
                        if let lastSeen = host.lastSeen {
                            Text(RelativeDateTimeFormatter().localizedString(for: lastSeen, relativeTo: Date()))
                                .font(DS.Font.detail)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Forget", role: .destructive) { confirmForget(host) }
                    } else if let host = unpaired.first(where: { $0.id == selectedHostID }) {
                        Spacer()
                        Button("Pair") { pairingHost = host }
                    } else {
                        Spacer()
                    }
                }
                .buttonStyle(.bordered)
                .tint(Color(.label))
                .frame(minHeight: 28)
            }
        }

        private var selectedPaired: PairedRemoteHost? {
            directory.paired.first { $0.id == selectedHostID }
        }

        private func saveNickname() {
            guard let host = selectedPaired, nickname != (host.nickname ?? "") else { return }
            PairedRemoteHostStore.setNickname(nickname, forHostID: host.id)
        }

        private func confirmForget(_ host: PairedRemoteHost) {
            AlertViewController(
                title: "Forget “\(host.displayName)”?",
                message: "To connect again, pair it again.",
                actions: [
                    AlertAction("Cancel") {},
                    AlertAction("Forget", kind: .destructive) {
                        PairedRemoteHostStore.remove(id: host.id)
                        selectedHostID = nil
                    },
                ],
            ).present(in: window)
        }
    }

    /// One row of a device table: the name with its address dim after it,
    /// a dim trailing detail, striped, the selection in the accent.
    private struct MacDeviceRow: View {
        let name: String
        let address: String?
        let detail: String
        let index: Int
        let isSelected: Bool
        let select: () -> Void

        var body: some View {
            Button(action: select) {
                HStack(spacing: DS.Padding.m) {
                    Group {
                        if let address {
                            Text(verbatim: name)
                                + Text(verbatim: " @\(address)").foregroundColor(isSelected ? .white.opacity(0.75) : .secondary)
                        } else {
                            Text(verbatim: name)
                        }
                    }
                    .lineLimit(1)
                    Spacer(minLength: DS.Padding.m)
                    Text(verbatim: detail)
                        .font(DS.Font.detail)
                        .foregroundColor(isSelected ? .white.opacity(0.75) : .secondary)
                        .lineLimit(1)
                }
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, DS.Padding.m)
                .padding(.vertical, DS.Padding.xs + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isSelected ? Color.accentColor : MacTableStripe.color(index))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
    }

#endif
