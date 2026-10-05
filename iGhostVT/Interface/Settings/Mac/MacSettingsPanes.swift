//
//  MacSettingsPanes.swift
//  iGhostVT
//

import GhosttyTerminal
import SwiftUI

#if targetEnvironment(macCatalyst)

    /// The panes of the Mac's settings window, one per toolbar item. The
    /// settings are the ones the iPhone and iPad sheet holds, read from the
    /// same stores; only the layout is the Mac's.
    enum MacSettingsPane: String, CaseIterable {
        case general
        case appearance
        case keyboard
        case remote
        case configuration
        case advanced
        case about

        var title: String {
            switch self {
            case .general: String(localized: "General")
            case .appearance: String(localized: "Appearance")
            case .keyboard: String(localized: "Keyboard")
            case .remote: String(localized: "Remote Access")
            case .configuration: String(localized: "Configuration")
            case .advanced: String(localized: "Advanced")
            case .about: String(localized: "About")
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "paintpalette"
            case .keyboard: "keyboard"
            case .remote: "network"
            case .configuration: "doc.text"
            case .advanced: "gearshape.2"
            case .about: "info.circle"
            }
        }

        /// The height of a pane whose content scrolls — a list, a file, a
        /// log — in the app's points. Nil for a pane the window fits to.
        var fixedHeight: CGFloat? {
            switch self {
            case .general, .appearance, .advanced: nil
            case .keyboard, .remote, .configuration, .about: 560
            }
        }

        @MainActor @ViewBuilder
        var content: some View {
            switch self {
            case .general: MacGeneralPane()
            case .appearance: MacAppearancePane()
            case .keyboard: MacShortcutsPane()
            case .remote: RemoteAccessView()
            case .configuration: MacConfigurationPane()
            case .advanced: MacAdvancedPane()
            case .about: MacAboutPane()
            }
        }
    }

    /// The shell, what quitting does to sessions, the background helper,
    /// and the new-tab menu's recent directories.
    private struct MacGeneralPane: View {
        @AppStorage("Shell.path") private var shellPath = ""
        @State private var availableShellPaths: [String]?
        @State private var isEditingCustomShell = false
        @FocusState private var shellPathIsFocused: Bool

        @AppStorage(SessionKeepAlive.key) private var keepAlive = true
        @ObservedObject private var agent = MacLaunchAgent.shared
        @ObservedObject private var recents = RecentDirectoryStore.shared

        var body: some View {
            MacSettingsForm {
                shellRow
                Divider()
                MacSettingsRow("Sessions") {
                    MacCheckbox(String(localized: "Keep Sessions Running"), isOn: $keepAlive)
                } details: {
                    MacSettingsNote(
                        """
                        Sessions with a program running keep going after the app quits \
                        and come back on the next launch; a shell sitting at its prompt \
                        closes. Turn this off to close every session when the app quits.
                        """,
                    )
                }
                if agent.status != .unsupported {
                    MacSettingsRow("Terminal Helper") {
                        Text(agent.status.settingsDescription)
                    } details: {
                        MacSettingsNote(
                            """
                            iGhostVT opens terminals through a helper that runs in \
                            the background, so sessions keep going while the app is \
                            closed. It is set up automatically. To remove it, turn \
                            iGhostVT off under Login Items in System Settings.
                            """,
                        )
                    }
                    .accessibilityElement(children: .combine)
                }
                Divider()
                recentDirectoriesRow
            }
            .onAppear {
                ShellMenuItems.loadAvailable { availableShellPaths = $0 }
            }
        }

        private var shellRow: some View {
            MacSettingsRow("Default Shell") {
                Menu {
                    ShellMenuItems(
                        shellPath: $shellPath,
                        available: availableShellPaths ?? [],
                        onChoose: {
                            isEditingCustomShell = false
                            shellPathIsFocused = false
                        },
                        onCustom: {
                            isEditingCustomShell = true
                            DispatchQueue.main.async {
                                shellPathIsFocused = true
                            }
                        },
                    )
                } label: {
                    MacPopupLabel(title: ShellMenuItems.title(of: shellPath))
                }
                .accessibilityLabel("Default Shell")
                .accessibilityValue(ShellMenuItems.title(of: shellPath))
            } details: {
                if ShellMenuItems.showsCustomPath(
                    shellPath,
                    available: availableShellPaths,
                    isEditing: isEditingCustomShell,
                ) {
                    TextField("Custom Path", text: $shellPath)
                        .textFieldStyle(.roundedBorder)
                        .focused($shellPathIsFocused)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .frame(maxWidth: 300)
                }
                MacSettingsNote(
                    """
                    Choose Automatic to use your login shell. Enter a custom \
                    executable path when it is not listed above.
                    """,
                )
            }
        }

        private var recentDirectoriesRow: some View {
            MacSettingsRow("Recent Directories") {
                MacCheckbox(String(localized: "Remember Directories"), isOn: $recents.isEnabled)
            } details: {
                if recents.isEnabled {
                    HStack(spacing: DS.Padding.s) {
                        Text("Sort By")
                        Menu {
                            RecentDirectorySortItems(recents: recents)
                        } label: {
                            MacPopupLabel(title: recents.sortOrder.title)
                        }
                        .frame(maxWidth: 200)
                        .accessibilityLabel("Sort By")
                        .accessibilityValue(recents.sortOrder.title)
                    }
                }
                MacSettingsNote(
                    """
                    New Tab offers the directories your terminals are in, then \
                    the ones they have been in before. Turn this off and that \
                    second list is neither offered nor added to; what is already \
                    remembered stays until you clear it.
                    """,
                )
                if !recents.entries.isEmpty {
                    Button(role: .destructive, action: { recents.clear() }) {
                        Text("Clear Recent Directories")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    /// The accent, the two theme slots and the two text sizes.
    private struct MacAppearancePane: View {
        @AppStorage(TerminalFontSize.key) private var terminalFontSize = TerminalFontSize.default
        @AppStorage(InterfaceTextSize.key) private var interfaceTextStep = 0

        var body: some View {
            MacSettingsForm {
                MacSettingsRow("Accent Color") {
                    AccentColorPicker()
                }
                MacSettingsRow("Light Theme") {
                    MacThemeMenuButton(slot: .light)
                }
                MacSettingsRow("Dark Theme") {
                    MacThemeMenuButton(slot: .dark)
                } details: {
                    MacSettingsNote(
                        "Themes come from the Ghostty theme catalog and apply to every tab in every window.",
                    )
                }
                Divider()
                MacSettingsRow("Terminal") {
                    // The value as text and the stepper bare beside it: a
                    // Stepper's own label sits on a line of its own here.
                    HStack(spacing: DS.Padding.m) {
                        SizeValue(text: Self.points(terminalFontSize))
                        Stepper("Terminal", value: $terminalFontSize, in: TerminalFontSize.range)
                            .labelsHidden()
                    }
                }
                MacSettingsRow("Interface") {
                    HStack(spacing: DS.Padding.m) {
                        SizeValue(text: Self.percent(interfaceTextStep))
                        Stepper("Interface", value: $interfaceTextStep, in: InterfaceTextSize.steps)
                            .labelsHidden()
                    }
                } details: {
                    MacSettingsNote(
                        """
                        New terminals open at the terminal size; a tab that is already \
                        open keeps the size it was zoomed to. The interface size scales \
                        every label and control.
                        """,
                    )
                }
            }
        }

        static func points(_ size: Int) -> String {
            String.localizedStringWithFormat(
                NSLocalizedString("%lld pt", comment: "A font size in points"),
                size,
            )
        }

        static func percent(_ step: Int) -> String {
            "\(Int((InterfaceTextSize.scale(step: step) * 100).rounded()))%"
        }

        /// Every value either row can show at its widest — the largest size
        /// in this language's spelling, the largest and smallest scale —
        /// so both value columns reserve one width and the two steppers
        /// start at the same x whatever the values are.
        static var widestValues: [String] {
            [
                points(TerminalFontSize.range.upperBound),
                points(TerminalFontSize.range.lowerBound),
                percent(InterfaceTextSize.steps.upperBound),
                percent(InterfaceTextSize.steps.lowerBound),
            ]
        }

        /// A size's value, trailing-aligned in a column as wide as the
        /// widest value either row can show. The candidates are laid out
        /// hidden underneath, so the width comes from the text itself and
        /// no frame is measured.
        private struct SizeValue: View {
            let text: String

            var body: some View {
                ZStack(alignment: .trailing) {
                    ForEach(Array(MacAppearancePane.widestValues.enumerated()), id: \.offset) { _, candidate in
                        Text(verbatim: candidate).hidden()
                    }
                    Text(verbatim: text)
                }
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            }
        }
    }

    /// The keystroke log's switch, and the logs themselves — opened in
    /// Console, which reads, searches and follows a log file better than
    /// anything a settings window could hold.
    private struct MacAdvancedPane: View {
        @AppStorage(DetailedTerminalLog.key) private var verboseTerminalLog = false
        @AppStorage(ZmodemSetting.key) private var zmodemEnabled = ZmodemSetting.defaultValue

        var body: some View {
            MacSettingsForm {
                MacSettingsRow("File Transfer") {
                    MacCheckbox(String(localized: "ZMODEM File Transfer"), isOn: $zmodemEnabled)
                } details: {
                    MacSettingsNote("Support for ZMODEM (`rz`/`sz`) file transfers.")
                }
                Divider()
                MacSettingsRow("Debugging") {
                    MacCheckbox(String(localized: "Detailed Terminal Log"), isOn: $verboseTerminalLog)
                        .onChange(of: verboseTerminalLog, perform: DetailedTerminalLog.apply)
                } details: {
                    MacSettingsNote(
                        """
                        Writes detailed terminal activity to the log, \
                        including every keystroke, while this is on.
                        """,
                    )
                }
                Divider()
                MacSettingsRow("Logs") {
                    HStack(spacing: DS.Padding.s) {
                        Button("Open App Log") {
                            open(AppLog.currentFile ?? AppLog.journalDirectory)
                        }
                        Button("Open Helper Log") {
                            open(URL(fileURLWithPath: iGhostVTProtocol.daemonLogPath))
                        }
                    }
                    .buttonStyle(.bordered)
                    // A Mac push button is grey with dark text; the accent
                    // is for the selected and the default, neither of these.
                    .tint(Color(.label))
                } details: {
                    MacSettingsNote("Logs open in Console.")
                }
            }
        }

        /// The file in the app the system opens logs with — Console — or,
        /// for a log not written yet, its folder in the Finder.
        private func open(_ url: URL) {
            let target = FileManager.default.fileExists(atPath: url.path)
                ? url
                : url.deletingLastPathComponent()
            UIApplication.shared.open(target)
        }
    }

    /// The app's name and version over every license it ships under.
    private struct MacAboutPane: View {
        var body: some View {
            VStack(spacing: 0) {
                VStack(spacing: DS.Padding.xs) {
                    // Shaped the way the Dock draws an app icon.
                    Image("AlertIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1),
                        )
                        .accessibilityHidden(true)
                    Text(verbatim: "iGhostVT")
                        .font(DS.Font.title)
                    HStack(spacing: DS.Padding.xs) {
                        Text("Version")
                        Text(verbatim: AboutSettingsSection.versionDescription)
                    }
                    .font(DS.Font.detail)
                    .foregroundColor(.secondary)
                    .accessibilityElement(children: .combine)
                }
                .padding(DS.Padding.l)
                .frame(maxWidth: .infinity)
                MacLicensesBrowser()
                    .padding([.horizontal, .bottom], DS.Padding.xl)
            }
        }
    }

#endif
