import SwiftUI
import AppKit
import ServiceManagement

/// App settings (Cmd+, or the menu bar panel's gear menu): the Dock icon
/// and launch at login.
@MainActor
struct SettingsView: View {
    @Bindable private var app = AppController.shared
    @State private var loginItem = LoginItem()

    var body: some View {
        Form {
            Section {
                Toggle("Show in Dock", isOn: $app.showInDock)
                Text(app.showInDock
                     ? "Closing the mixer window keeps the app running in the menu bar."
                     : "The app lives in the menu bar only — no Dock icon, no Cmd+Tab entry. Open the mixer from the menu bar panel.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                .disabled(!LoginItem.isAvailable)
                if let note = loginItem.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if loginItem.needsApproval {
                    Button("Open Login Items Settings…") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
        .background(WindowAccessor { AppController.shared.attachSettingsWindow($0) })
        // The user can also remove the login item in System Settings, so
        // re-read it whenever we come back to the app.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }
}

/// Launch at login via `SMAppService.mainApp` — registers this app bundle
/// as a login item (macOS 13+; listed under System Settings → General →
/// Login Items).
@MainActor
@Observable
final class LoginItem {
    private(set) var status: SMAppService.Status = .notRegistered
    private var error: String?

    /// Login items need a real app bundle; `swift run` has none.
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    init() { refresh() }

    func refresh() {
        guard Self.isAvailable else { return }
        status = SMAppService.mainApp.status
    }

    /// On, or on but waiting for the user's approval in System Settings.
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    var note: String? {
        if !Self.isAvailable { return "Available when running the bundled app." }
        if let error { return error }
        if needsApproval { return "Waiting for approval in System Settings → General → Login Items." }
        return nil
    }

    func setEnabled(_ on: Bool) {
        error = nil
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            self.error = "Couldn't \(on ? "turn on" : "turn off") launch at login: \(error.localizedDescription)"
        }
        refresh()
    }
}
