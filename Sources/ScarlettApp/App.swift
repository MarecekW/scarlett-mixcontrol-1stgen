import SwiftUI
import AppKit

// The activation policy is set after launch from the "Show in Dock" setting
// (see `AppController`): the bundle declares a menu bar app (LSUIElement) so
// no Dock icon flashes up when the setting is off, and a bare Swift Package
// executable has no Info.plist at all.
final class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        // Without an .app bundle (we're a Swift Package executable),
        // NSApplication uses the executable filename ("scarlett-app") for
        // the menu-bar title and the Dock label.  Overriding the process
        // name BEFORE NSApp builds the default menu bar gets us the
        // "Scarlett MixControl" title we actually want.
        ProcessInfo.processInfo.processName = "Scarlett MixControl"
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force AppKit-backed controls (Picker .menu = NSPopUpButton, Menu,
        // context menus, etc.) to use dark appearance regardless of the
        // user's system setting. SwiftUI's .preferredColorScheme only
        // affects SwiftUI views, not the embedded AppKit controls.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // Activation policy (Dock icon or menu bar only) and whether the
        // mixer window stays open at launch.
        AppController.shared.finishLaunching()

        // Runtime icon comes from Contents/Resources/AppIcon.icns (CFBundleIconFile).
        // No NSApp.applicationIconImage override — avoids lockFocus drawing and
        // any Bundle.module access in packaged builds.
    }

    // The menu bar panel keeps working with the window closed; only Quit
    // ends the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Opening the app again (Finder, Spotlight, Dock click) while it runs
    // brings the mixer back — with no Dock icon there's no other cue.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppController.shared.showMainWindow()
        return false
    }
}

@main
struct ScarlettApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var state = MixerState()

    var body: some Scene {
        Window("Scarlett MixControl", id: AppController.mainWindowID) {
            ContentView(state: state)
                .background(WindowAccessor { AppController.shared.attachMainWindow($0) })
                .frame(
                    minWidth: 1100,
                    idealWidth: 1340,
                    maxWidth: .infinity,
                    minHeight: 580,
                    idealHeight: 720,
                    maxHeight: .infinity
                )
        }
        .windowResizability(.contentSize)
        .commands {
            // Replace the default File-menu commands so we can plug in
            // snapshot Save/Open.  Removed-by-default items (New Window,
            // Print, etc.) stay removed; we just add ours.
            CommandGroup(replacing: .saveItem) {
                Button("Save snapshot…") {
                    exportSnapshot(state: state)
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button("Open snapshot…") {
                    importSnapshot(state: state)
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
        }

        // Cmd+, — also opened from the menu bar panel's gear menu.
        Settings {
            SettingsView()
        }

        // Always present: with the Dock icon hidden it's the only way back
        // to the app.
        MenuBarExtra {
            MenuBarPanel(state: state)
        } label: {
            MenuBarIcon(state: state)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
private func exportSnapshot(state: MixerState) {
    let panel = NSSavePanel()
    // No `allowedContentTypes`: NSSavePanel would otherwise auto-append
    // the canonical extension of the chosen UTType (e.g. ".json"), which
    // mangles our `.scmx` extension into "…​.scmx.json".
    // The extension is device-agnostic, while the snapshot contents record the
    // originating product ID so routes cannot be applied to the wrong model.
    // Older `.8i6` files still open through the legacy compatibility checks.
    panel.allowsOtherFileTypes = true
    panel.nameFieldStringValue = "ScarlettSnapshot.scmx"
    panel.title = "Save Scarlett snapshot"
    if panel.runModal() == .OK, let url = panel.url {
        do { try state.userExportSnapshot(to: url) }
        catch {
            NSAlert(error: error).runModal()
        }
    }
}

@MainActor
private func importSnapshot(state: MixerState) {
    let panel = NSOpenPanel()
    // No content-type filter — the user might have a `.scmx`, an older
    // `.8i6`, or a `.json` file (all valid; contents are checked at decode time).
    panel.allowsMultipleSelection = false
    panel.title = "Open Scarlett snapshot"
    if panel.runModal() == .OK, let url = panel.url {
        do { try state.userImportSnapshot(from: url) }
        catch {
            NSAlert(error: error).runModal()
        }
    }
}
