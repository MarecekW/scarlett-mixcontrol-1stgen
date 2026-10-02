import SwiftUI

// Shared controls: the pill button face used across the app, the
// click-confirming `FeedbackButton`, and the themed menu picker.

// MARK: - Pill

/// Pill sizes, one per context so buttons of a kind match.
enum PillSize {
    /// Preset rows and the save field.
    case row
    /// Mixer toolbar.
    case toolbar
    /// Centred cards (connection, first launch).
    case card

    var iconFont: Font {
        .system(size: self == .card ? 11 : 10, weight: .semibold)
    }
    var titleFont: Font {
        .system(size: self == .card ? 12 : 11, weight: .semibold)
    }
    var horizontalPadding: CGFloat {
        switch self {
        case .row:     return 12
        case .toolbar: return 10
        case .card:    return 14
        }
    }
    var verticalPadding: CGFloat {
        switch self {
        case .row:     return 5
        case .toolbar: return 6
        case .card:    return 7
        }
    }
    var cornerRadius: CGFloat {
        switch self {
        case .row:     return 3
        case .toolbar: return 4
        case .card:    return 5
        }
    }
}

extension View {
    /// Padding, fill and rounded clip of a pill.  For pills whose content
    /// isn't just icon + title (e.g. the master mute's crossfading icon).
    func pillChrome(_ size: PillSize, fill: Color, foreground: Color,
                    fillsWidth: Bool = false) -> some View {
        padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .background(fill)
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: size.cornerRadius))
    }
}

/// The app's button face: optional SF Symbol + title on a rounded fill.
/// Use as a `Button` label together with `PillButtonStyle`.
struct Pill: View {
    var icon: String? = nil
    let title: String
    /// Extra symbol after the title (the chevron on a menu pill).
    var trailingIcon: String? = nil
    var fill: Color = Theme.panelRaised
    var foreground: Color = Theme.textSecondary
    var size: PillSize = .toolbar
    /// Stretch to the proposed width — set when stacking pills of
    /// different lengths so they share the widest one's width.
    var fillsWidth = false

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon).font(size.iconFont)
            }
            Text(title).font(size.titleFont).lineLimit(1)
            if let trailingIcon {
                Image(systemName: trailingIcon).font(.system(size: 8, weight: .semibold))
            }
        }
        .pillChrome(size, fill: fill, foreground: foreground, fillsWidth: fillsWidth)
    }
}

/// Plain button behaviour for pill labels: no system chrome, dims while
/// pressed and when disabled.
struct PillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.5)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
}

// MARK: - Click feedback

/// Outcome a `FeedbackButton` shows after its action runs.
enum FeedbackPhase: CaseIterable {
    case idle, done, failed
}

/// A button that briefly swaps its label for a confirmation ("Saved",
/// "Cleared") or a failure, then reverts.  Every phase's label is laid out
/// at once and only the current one is visible, so the button keeps the
/// width of its widest label and nothing around it shifts.
struct FeedbackButton<Content: View>: View {
    /// Returns true on success.  Async so a USB write can report back.
    let action: () async -> Bool
    @ViewBuilder let label: (FeedbackPhase) -> Content
    @State private var phase: FeedbackPhase = .idle
    /// Clicks are ignored while the action runs, so a double-click can't
    /// e.g. queue two flash writes.
    @State private var running = false
    /// Bumped per click so an older click's timer can't reset a newer one.
    @State private var clickID = 0

    var body: some View {
        Button {
            guard !running else { return }
            running = true
            clickID += 1
            let id = clickID
            Task {
                let ok = await action()
                running = false
                phase = ok ? .done : .failed
                try? await Task.sleep(for: .seconds(1.5))
                if clickID == id { phase = .idle }
            }
        } label: {
            ZStack {
                ForEach(FeedbackPhase.allCases, id: \.self) { p in
                    label(p)
                        .opacity(p == phase ? 1 : 0)
                        .accessibilityHidden(p != phase)
                }
            }
            .animation(.easeOut(duration: 0.15), value: phase)
        }
    }
}

/// Pill face for a `FeedbackButton`: the idle pill, then a green
/// "✓ <done>" or a red "✗ Failed" at the same width.  Pair with
/// `.buttonStyle(.pill)` and `.fixedSize()`.
struct FeedbackPill: View {
    let phase: FeedbackPhase
    var icon: String? = nil
    let title: String
    let doneTitle: String
    var fill: Color = Theme.panelRaised
    var foreground: Color = Theme.textSecondary
    var size: PillSize = .toolbar

    var body: some View {
        switch phase {
        case .idle:
            Pill(icon: icon, title: title, fill: fill, foreground: foreground,
                 size: size, fillsWidth: true)
        case .done:
            Pill(icon: "checkmark", title: doneTitle,
                 fill: Theme.success.opacity(Theme.statusFillOpacity),
                 foreground: Theme.success, size: size, fillsWidth: true)
        case .failed:
            Pill(icon: "xmark", title: "Failed",
                 fill: Theme.failure.opacity(Theme.statusFillOpacity),
                 foreground: Theme.failure, size: size, fillsWidth: true)
        }
    }
}

/// Label for a system-styled `FeedbackButton` (bordered macOS buttons).
struct FeedbackLabel: View {
    let phase: FeedbackPhase
    let title: String
    let doneTitle: String

    var body: some View {
        switch phase {
        case .idle:   Text(title)
        case .done:   Label(doneTitle, systemImage: "checkmark").foregroundStyle(Theme.success)
        case .failed: Label("Failed", systemImage: "xmark").foregroundStyle(Theme.failure)
        }
    }
}

// MARK: - Menu picker

/// A drop-in replacement for SwiftUI's `Picker(.menu)` that always renders
/// with theme-controlled colors. `Picker(.menu)` on macOS is backed by
/// `NSPopUpButton` and stubbornly ignores `.foregroundStyle` /
/// `NSAppearance` overrides in some configurations, leaving us with dark
/// text on dark panels. `Menu` gives us full label control.
struct ThemedMenuPicker<T: Hashable & Identifiable>: View {
    let options: [T]
    let displayName: (T) -> String
    @Binding var selection: T
    var width: CGFloat? = nil
    var horizontalPadding: CGFloat = 6
    var verticalPadding: CGFloat = 3
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Menu {
            ForEach(options) { item in
                Button(displayName(item)) { selection = item }
            }
        } label: {
            HStack(spacing: 4) {
                Text(displayName(selection))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(width: width)
            .background(Theme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: width == nil, vertical: true)
        .opacity(isEnabled ? 1.0 : 0.4)
    }
}

// MARK: - Mute all

/// Toggles the master mute — in the mixer's toolbar and the menu bar
/// panel.  The label morphs between "Mute all" and "Master muted".  The
/// toggle runs inside `withAnimation` so the surrounding row re-lays out in
/// step (width grows, neighbours slide); the icon rides the leading edge
/// and crossfades in place, and the two labels are separate views that
/// crossfade.
@MainActor
struct MasterMuteButton: View {
    @Bindable var state: MixerState

    var body: some View {
        let muted = state.masterMuted
        Button {
            withAnimation(.snappy(duration: 0.25)) {
                state.userSetMasterMute(!muted)
            }
        } label: {
            HStack(spacing: 5) {
                // One fixed slot that travels with the button's leading edge;
                // the two icons crossfade inside it.
                ZStack {
                    Image(systemName: "speaker.wave.2").opacity(muted ? 0 : 1)
                    Image(systemName: "speaker.slash.fill").opacity(muted ? 1 : 0)
                }
                .font(PillSize.toolbar.iconFont)
                .frame(width: 14)
                Group {
                    if muted {
                        Text("Master muted")
                    } else {
                        Text("Mute all")
                    }
                }
                .font(PillSize.toolbar.titleFont)
                .lineLimit(1)
                .transition(.opacity)
            }
            .pillChrome(.toolbar,
                        fill: muted ? Theme.muteActive : Theme.panelRaised,
                        foreground: muted ? .white : Theme.textSecondary)
        }
        .buttonStyle(.pill)
        .fixedSize()
        .help("Mute every output bus on the device.")
    }
}
