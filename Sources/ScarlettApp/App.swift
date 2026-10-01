import SwiftUI
import AppKit

// Swift Package executables don't have an Info.plist marking them as regular
// apps; without help the window comes up behind other apps with no Dock icon.
// Set activation policy after launch via an NSApplicationDelegate.
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
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Force AppKit-backed controls (Picker .menu = NSPopUpButton, Menu,
        // context menus, etc.) to use dark appearance regardless of the
        // user's system setting. SwiftUI's .preferredColorScheme only
        // affects SwiftUI views, not the embedded AppKit controls.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // Let the window content extend behind the title bar so the
        // sidebar's background can run continuously from the very top of
        // the window down — otherwise there's a strip of plain title-bar
        // chrome between the sidebar and the rest of the window.
        DispatchQueue.main.async {
            for win in NSApp.windows {
                win.titlebarAppearsTransparent = true
                // The sidebar header already shows the name; a visible title
                // would force the sidebar wide enough to sit behind it.
                win.titleVisibility = .hidden
                win.styleMask.insert(.fullSizeContentView)
            }
        }

        // Runtime icon comes from Contents/Resources/AppIcon.icns (CFBundleIconFile).
        // No NSApp.applicationIconImage override — avoids lockFocus drawing and
        // any Bundle.module access in packaged builds.
    }
}

@main
struct ScarlettApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var state = MixerState()

    var body: some Scene {
        Window("Scarlett MixControl", id: "main") {
            ContentView(state: state)
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
