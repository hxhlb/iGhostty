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
        @State private var isImportingRelay = false
        @AppStorage(RelayConfigurationStore.allowsRelayPairingKey) private var allowsRelayPairing = false

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
                        if directory.relay == nil {
                            MacSettingsNote("Paired devices on this network can open terminals here.")
                        } else {
                            MacSettingsNote("Paired devices on this network, or anywhere through the relay, can open terminals here.")
                        }
                    }
                }
                relayRow
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
            .fileImporter(
                isPresented: $isImportingRelay,
                allowedContentTypes: [RelayImportType.type],
            ) { result in
                if case let .success(url) = result {
                    RelayImport.open(url, in: window)
                }
            }
        }

        // MARK: - Relay

        private var relayRow: some View {
            MacSettingsRow("Relay") {
                if let relay = directory.relay {
                    VStack(alignment: .leading, spacing: DS.Padding.s) {
                        HStack(spacing: DS.Padding.m) {
                            Text(verbatim: relay.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Replace…") { isImportingRelay = true }
                            Button("Remove") { RelayConfigurationStore.remove() }
                        }
                        MacCheckbox(String(localized: "Allow Pairing Through Relay"), isOn: $allowsRelayPairing)
                    }
                } else {
                    Button("Import Relay Configuration…") { isImportingRelay = true }
                }
            } details: {
                if let relay = directory.relay {
                    let status = RelayStatusText.describe(model.status, directory: directory)
                    Text(verbatim: [relay.endpointDescription, status?.text].compactMap { $0 }.joined(separator: " · "))
                        .font(DS.Font.detail)
                        .foregroundColor(status?.isProblem == true ? .red : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    MacSettingsNote(
                        "A relay lets your devices reach each other when they are not on the same network. Set one up on a server and import the .vtrpsc file it writes.",
                    )
                }
            }
        }

        private func saveName() {
            guard name != (RemoteDeviceIdentity.chosenName ?? "") else { return }
            model.setName(name)
        }

        // MARK: - This Mac as a host

        /// The devices that may open terminals here: + under the table pairs
        /// one more, the selected row's trash takes one away.
        private var allowedDevices: some View {
            VStack(alignment: .leading, spacing: DS.Padding.s) {
                Text("Allowed Devices")
                    .font(DS.Font.labelEmphasis)
                MacTableFrame {
                    VStack(spacing: 0) {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(model.status.devices.enumerated()), id: \.element.id) { index, device in
                                    MacDeviceRow(
                                        name: device.name,
                                        address: nil,
                                        detail: RemoteAccessView.lastSeenText(device),
                                        index: index,
                                        isSelected: device.id == selectedAllowedID,
                                        select: { selectedAllowedID = device.id },
                                    ) {
                                        MacRowIconButton(symbol: "trash", label: "Remove") {
                                            model.revoke(device)
                                            selectedAllowedID = nil
                                        }
                                    }
                                    .contextMenu {
                                        Button("Remove", role: .destructive) { model.revoke(device) }
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: .infinity)
                        .overlay {
                            if model.status.devices.isEmpty {
                                Text("Pair a device to let it open terminals here.")
                                    .font(DS.Font.detail)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Divider()
                        MacTableBar {
                            Button {
                                Task {
                                    await model.beginPairing()
                                    isShowingPairingCode = true
                                }
                            } label: {
                                Image(systemName: "plus")
                                    .frame(width: 22, height: 18)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Pair New Device…")
                            .disabled(model.status.state != .listening)
                            .popover(isPresented: $isShowingPairingCode, arrowEdge: .bottom) {
                                RemotePairingCodeView(model: model, isPopover: true)
                            }
                        }
                    }
                }
                .frame(height: Self.tableHeight + macTableBarHeight)
            }
        }

        /// One height for both tables, never the content's: rows coming
        /// and going scroll inside it.
        private static let tableHeight: CGFloat = 112

        // MARK: - The other devices

        /// The devices this Mac is paired with, then the ones nearby it
        /// could pair with. The selected row carries its one action — trash
        /// to forget a paired device, Pair for one nearby — and a paired
        /// device's name can be changed under the table.
        private var yourDevices: some View {
            let unpaired = directory.unpairedNearby + directory.unpairedAtRelay
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
                                    detail: directory.mismatchedVersion(of: host.id).map(RemoteVersionText.needsUpdate(theirs:))
                                        ?? RemoteAccessView.whereabouts(of: host.id, in: directory),
                                    index: index,
                                    isSelected: host.id == selectedHostID,
                                    select: { selectedHostID = host.id },
                                ) {
                                    MacRowIconButton(symbol: "trash", label: "Forget") {
                                        confirmForget(host)
                                    }
                                }
                            }
                            ForEach(Array(unpaired.enumerated()), id: \.element.id) { offset, host in
                                MacDeviceRow(
                                    name: host.name,
                                    address: host.address,
                                    detail: host.viaRelay ? String(localized: "Through relay") : "",
                                    index: directory.paired.count + offset,
                                    isSelected: host.id == selectedHostID,
                                    select: { selectedHostID = host.id },
                                ) {
                                    Button("Pair") { pairingHost = host }
                                        .buttonStyle(.borderless)
                                        .foregroundColor(.white)
                                        .font(DS.Font.labelEmphasis)
                                        .popover(item: $pairingHost, arrowEdge: .trailing) { host in
                                            RemotePairDeviceView(host: host, isPopover: true)
                                        }
                                }
                            }
                        }
                    }
                    .overlay {
                        if directory.paired.isEmpty, unpaired.isEmpty {
                            Group {
                                if directory.relay == nil {
                                    Text("Devices on this network with remote access on appear here.")
                                } else {
                                    Text("Devices on this network or at the relay with remote access on appear here.")
                                }
                            }
                            .font(DS.Font.detail)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(DS.Padding.m)
                        }
                    }
                }
                .frame(height: Self.tableHeight)
                // Always laid out, so selecting a row moves nothing.
                HStack(spacing: DS.Padding.s) {
                    if let host = selectedPaired {
                        Text("Name")
                        TextField(host.name, text: $nickname)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                            .frame(maxWidth: 240)
                            .onSubmit(saveNickname)
                            .accessibilityLabel("Name")
                        if let lastSeen = host.lastSeen {
                            Text(RelativeDateTimeFormatter().localizedString(for: lastSeen, relativeTo: Date()))
                                .font(DS.Font.detail)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .frame(height: 28)
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
                    AlertAction("Forget", kind: .highlighted) {
                        PairedRemoteHostStore.remove(id: host.id)
                        selectedHostID = nil
                    },
                ],
            ).present(in: window)
        }
    }

    /// One row of a device table: the name with its address dim after it,
    /// a dim trailing detail, striped, the selection in the accent with the
    /// row's action at its trailing end.
    private struct MacDeviceRow<Accessory: View>: View {
        let name: String
        let address: String?
        let detail: String
        let index: Int
        let isSelected: Bool
        let select: () -> Void
        @ViewBuilder let accessory: () -> Accessory

        var body: some View {
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
                if isSelected {
                    accessory()
                }
            }
            .foregroundColor(isSelected ? .white : .primary)
            .padding(.horizontal, DS.Padding.m)
            // The accessory never makes a row taller than one without.
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor : MacTableStripe.color(index))
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
    }

    /// A glyph button on a selected row, white on the accent.
    private struct MacRowIconButton: View {
        let symbol: String
        let label: LocalizedStringKey
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .foregroundColor(.white)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(label)
        }
    }

    /// The strip under a table that holds its + button, as AppKit's
    /// gradient-button bar does.
    private let macTableBarHeight: CGFloat = 28

    private struct MacTableBar<Content: View>: View {
        @ViewBuilder let content: () -> Content

        var body: some View {
            HStack(spacing: 0) {
                content()
                    .buttonStyle(.borderless)
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, DS.Padding.xs)
            .frame(height: macTableBarHeight)
            .background(Color(.secondarySystemBackground).opacity(0.5))
        }
    }

#endif
