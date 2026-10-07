//
//  ShellSettingsSection.swift
//  iGhostVT
//

import SwiftUI

/// The shell every new terminal runs: Automatic, one the daemon found
/// installed, or a path typed in.
struct ShellSettingsSection: View {
    /// Read by the daemon when spawning shells. Empty means "let the daemon
    /// pick", using the session user's configured shell or its fallback.
    @AppStorage("Shell.path") private var shellPath = ""
    @State private var availableShellPaths: [String]?
    @State private var isEditingCustomShell = false
    @FocusState private var shellPathIsFocused: Bool

    /// The path field is the choice: being edited, or holding a path the
    /// menu does not list.
    private var isCustomShell: Bool {
        ShellMenuItems.showsCustomPath(shellPath, available: availableShellPaths, isEditing: isEditingCustomShell)
    }

    var body: some View {
        shellSection
            .onAppear(perform: loadAvailableShellPaths)
    }

    private var shellSection: some View {
        Section {
            HStack {
                Text("Shell")
                    .layoutPriority(1)
                Spacer()
                Menu {
                    ShellMenuItems(
                        shellPath: $shellPath,
                        available: availableShellPaths ?? [],
                        isCustom: isCustomShell,
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
                    HStack(spacing: DS.Padding.xs) {
                        Text(ShellMenuItems.title(of: shellPath, isCustom: isCustomShell))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down")
                            .imageScale(.small)
                    }
                }
                .accessibilityLabel("Default Shell")
                .accessibilityValue(ShellMenuItems.title(of: shellPath, isCustom: isCustomShell))
            }

            if isCustomShell {
                TextField("Custom Path", text: $shellPath)
                    .focused($shellPathIsFocused)
                    // Left empty, the field goes and the menu reads Automatic again.
                    .onChange(of: shellPathIsFocused) { focused in
                        if !focused, shellPath.isEmpty {
                            isEditingCustomShell = false
                        }
                    }
                    .keyboardType(.asciiCapable)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
            }
        } header: {
            Text("Default Shell")
                .font(DS.Font.caption)
        } footer: {
            // The bootstrap-root caveat is a device matter; a Mac has no
            // bootstrap to prefix a path with.
            #if targetEnvironment(macCatalyst)
                Text(
                    """
                    Choose Automatic to use your login shell. Enter a custom \
                    executable path when it is not listed above.
                    """,
                )
                .font(DS.Font.detail)
            #else
                Text(
                    """
                    Choose Automatic to use the default login shell. Custom paths \
                    must not include the bootstrap root, which can change when the \
                    environment is recreated.
                    """,
                )
                .font(DS.Font.detail)
            #endif
        }
    }

    private func loadAvailableShellPaths() {
        ShellMenuItems.loadAvailable { availableShellPaths = $0 }
    }
}

/// The shell menu's items — Automatic, every shell the daemon found, and
/// Custom… — shared by this section and the Mac's settings window. Buttons,
/// not a Picker: Catalyst draws a Picker inside a Menu as a submenu titled
/// with the picker's label, so the two sections came out as two identically
/// named submenus.
struct ShellMenuItems: View {
    @Binding var shellPath: String
    let available: [String]
    /// Whether the path field is the choice, so Custom… is the item checked.
    var isCustom = false
    /// A listed shell picked: the caller puts its path field away.
    let onChoose: () -> Void
    /// Custom… picked: the caller shows the path field and focuses it.
    let onCustom: () -> Void

    var body: some View {
        choice(String(localized: "Automatic"), path: "", isChecked: !isCustom && shellPath.isEmpty)
        Divider()
        ForEach(available, id: \.self) { path in
            choice(path, path: path, isChecked: !isCustom && shellPath == path)
        }
        Divider()
        Button(action: onCustom) {
            if isCustom {
                Label("Custom…", systemImage: "checkmark")
            } else {
                Text("Custom…")
            }
        }
    }

    /// One row of the menu, checked when it is the current choice.
    private func choice(_ title: String, path: String, isChecked: Bool) -> some View {
        Button {
            shellPath = path
            onChoose()
        } label: {
            if isChecked {
                Label(title, systemImage: "checkmark")
            } else {
                Text(verbatim: title)
            }
        }
    }

    /// What the menu's button reads: Custom while the path field is the
    /// choice — it holds the path — else the shell picked.
    static func title(of shellPath: String, isCustom: Bool = false) -> String {
        if isCustom {
            return String(localized: "Custom")
        }
        return shellPath.isEmpty ? String(localized: "Automatic") : shellPath
    }

    /// The path field shows while it is being edited, and for a stored path
    /// the menu does not list — once the list has arrived.
    static func showsCustomPath(_ shellPath: String, available: [String]?, isEditing: Bool) -> Bool {
        if isEditing {
            return true
        }
        guard let available, !shellPath.isEmpty else { return false }
        return !available.contains(shellPath)
    }

    /// Asks the daemon which shells are installed; `apply` runs on the main
    /// actor, and not at all when the daemon did not answer.
    static func loadAvailable(_ apply: @escaping @MainActor ([String]) -> Void) {
        XPCDaemonTransport.listShells { paths in
            guard let paths else { return }
            Task { @MainActor in
                apply(paths)
            }
        }
    }
}
