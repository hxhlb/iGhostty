//
//  SettingsPresentation.swift
//  iGhostVT
//

import SwiftUI

extension View {
    /// Presents settings the way each platform wants it. iPhone and iPad get
    /// `SettingsSheet` in the system sheet. The Mac opens its settings
    /// window (`SettingsWindow`) — or brings it forward — and the flag goes
    /// straight back down: the window lives apart from the one that asked,
    /// so there is nothing here to dismiss.
    func settingsPresentation(
        isPresented: Binding<Bool>,
        onDismiss: @escaping () -> Void = {},
    ) -> some View {
        #if targetEnvironment(macCatalyst)
            onChange(of: isPresented.wrappedValue) { shown in
                guard shown else { return }
                isPresented.wrappedValue = false
                SettingsWindow.open()
            }
        #else
            sheet(isPresented: isPresented, onDismiss: onDismiss) {
                SettingsSheet()
            }
        #endif
    }
}
