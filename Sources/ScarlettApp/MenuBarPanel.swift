import SwiftUI
import ScarlettCore

// MARK: - MenuBarIcon

/// The status item's icon.  Also hands SwiftUI's `openWindow` to
/// `AppController`: the label exists for the app's whole lifetime, unlike
/// the mixer window or the panel.
@MainActor
struct MenuBarIcon: View {
    @Bindable var state: MixerState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "slider.vertical.3")
            .onAppear { AppController.shared.openWindowAction = openWindow }
    }
}

// MARK: - MenuBarPanel

/// Compact controls shown when the menu bar icon is clicked.
@MainActor
struct MenuBarPanel: View {
    @Bindable var state: MixerState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Open Mixer") { AppController.shared.showMainWindow() }
            Button("Quit Scarlett MixControl") { AppController.shared.quit() }
        }
        .padding(12)
        .frame(width: 300)
    }
}
