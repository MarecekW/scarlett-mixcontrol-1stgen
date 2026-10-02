import SwiftUI
import AppKit

/// App-level lifecycle shared by the app delegate, the main window and the
/// menu bar panel: the Dock-icon policy, (re)opening the mixer window, and
/// quitting.  The app keeps running with no window open — the menu bar icon
/// is always there to bring the mixer back.
@MainActor
@Observable
final class AppController {
    static let shared = AppController()

    static let mainWindowID = "main"

    private static let showInDockKey   = "scarlett.app.showInDock.v1"
    private static let hasLaunchedKey  = "scarlett.app.hasLaunched.v1"

    /// Whether the app has a Dock icon — and with it a Cmd+Tab entry and the
    /// top menu bar.  Off = a menu-bar-only utility (`.accessory` policy).
    var showInDock: Bool {
        didSet {
            guard showInDock != oldValue else { return }
            UserDefaults.standard.set(showInDock, forKey: Self.showInDockKey)
            applyActivationPolicy()
        }
    }

    /// SwiftUI's `openWindow`, captured from a view's environment — AppKit
    /// code (the app delegate) has no other way to open a SwiftUI scene once
    /// its window has been closed.  Set by both the menu bar icon and the
    /// mixer view, so it's there even if the status item is hidden.
    @ObservationIgnored var openWindowAction: OpenWindowAction?

    /// The mixer window, recorded by a `WindowAccessor` each time SwiftUI
    /// creates it.  Weak: SwiftUI owns it and may discard it on close.
    @ObservationIgnored private weak var mainWindow: NSWindow?
    /// The Settings window, recorded the same way.
    @ObservationIgnored private weak var settingsWindow: NSWindow?
    /// The menu bar panel's window, which AppKit keeps and orders out
    /// while the panel is closed.
    @ObservationIgnored private weak var panelWindow: NSWindow?

    /// Set at launch when the app should start in the menu bar only; the
    /// window SwiftUI opens at launch is closed as soon as it attaches.
    @ObservationIgnored private var closeWindowOnAttach = false

    private init() {
        showInDock = UserDefaults.standard.object(forKey: Self.showInDockKey) as? Bool ?? true
    }

    // MARK: - Launch

    func finishLaunching() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)

        // With the Dock icon hidden the app starts quietly in the menu bar
        // (as at login).  The very first run always shows the window so a
        // new user isn't left wondering where the app went.
        let defaults = UserDefaults.standard
        let firstRun = !defaults.bool(forKey: Self.hasLaunchedKey)
        defaults.set(true, forKey: Self.hasLaunchedKey)

        if showInDock || firstRun {
            NSApp.activate(ignoringOtherApps: true)
        } else if let win = mainWindow {
            win.close()
        } else {
            closeWindowOnAttach = true
        }
    }

    // MARK: - Main window

    /// Called by a `WindowAccessor` once the mixer view is in a window.
    func attachMainWindow(_ win: NSWindow) {
        mainWindow = win

        // Let the window content extend behind the title bar so the
        // sidebar's background can run continuously from the very top of
        // the window down — otherwise there's a strip of plain title-bar
        // chrome between the sidebar and the rest of the window.  Applied
        // per window: SwiftUI builds a fresh one each time it's reopened.
        win.titlebarAppearsTransparent = true
        // The sidebar header already shows the name; a visible title
        // would force the sidebar wide enough to sit behind it.
        win.titleVisibility = .hidden
        win.styleMask.insert(.fullSizeContentView)
        // No window restoration: a window closed at quit would otherwise
        // stay closed at the next launch, regardless of `finishLaunching`.
        win.isRestorable = false

        if closeWindowOnAttach {
            closeWindowOnAttach = false
            // Not while SwiftUI is still installing the view.
            DispatchQueue.main.async { win.close() }
        }
    }

    /// The mixer window is open, not minimised, and at least partly
    /// visible — i.e. its meters are worth polling.
    var isMainWindowOnScreen: Bool {
        guard let win = mainWindow else { return false }
        return win.isVisible && !win.isMiniaturized && win.occlusionState.contains(.visible)
    }

    /// Bring the mixer window to the front, reopening it if it was closed.
    func showMainWindow() {
        closeWindowOnAttach = false
        if let win = mainWindow, win.isVisible || win.isMiniaturized {
            if win.isMiniaturized { win.deminiaturize(nil) }
            win.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?(id: Self.mainWindowID)
        }
        // Accessory apps aren't activated by opening a window; without this
        // the mixer comes up behind whatever app is in front.
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu bar panel

    func attachPanelWindow(_ win: NSWindow) {
        panelWindow = win
    }

    /// The menu bar panel is open — its meters are worth polling.
    var isPanelOnScreen: Bool {
        panelWindow?.isVisible ?? false
    }

    // MARK: - Settings window

    func attachSettingsWindow(_ win: NSWindow) {
        settingsWindow = win
    }

    /// Open Settings in front.  `openSettings` creates the window
    /// asynchronously, and from the menu bar panel the activation can lose
    /// to the panel closing — so activate, then front the window, on the
    /// next turn of the run loop.
    func showSettings(_ openSettings: OpenSettingsAction) {
        openSettings()
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            self.settingsWindow?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Dock icon

    private func applyActivationPolicy() {
        // Usually flipped from the Settings window, possibly with the mixer
        // open too.
        let visible = [mainWindow, settingsWindow].compactMap { $0 }.filter(\.isVisible)
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        // Switching policy deactivates the app and can push its windows
        // behind others; put whatever was showing back in front, the
        // window the user was in (Settings) last so it ends up key.
        guard !visible.isEmpty else { return }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            let ordered = visible.filter { $0 === self.mainWindow }
                + visible.filter { $0 !== self.mainWindow }
            for win in ordered { win.makeKeyAndOrderFront(nil) }
        }
    }

    // MARK: - Quit

    func quit() {
        NSApp.terminate(nil)
    }
}

/// Invisible view that reports the window hosting it to `AppController`.
struct WindowAccessor: NSViewRepresentable {
    let onAttach: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { TrackingView(onAttach: onAttach) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class TrackingView: NSView {
        let onAttach: @MainActor (NSWindow) -> Void

        init(onAttach: @escaping @MainActor (NSWindow) -> Void) {
            self.onAttach = onAttach
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onAttach(window) }
        }
    }
}
