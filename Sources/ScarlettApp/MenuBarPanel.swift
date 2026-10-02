import SwiftUI
import AppKit
import ScarlettCore

// MARK: - MenuBarIcon

/// The status item's icon: the mixer glyph, a slashed speaker while Mute
/// all is on, and dimmed while no device is connected.  Also hands SwiftUI's
/// `openWindow` to `AppController`: while shown, the label exists for the
/// app's whole lifetime, unlike the mixer window or the panel.  (With the
/// icon hidden, the mixer view hands it over instead.)
@MainActor
struct MenuBarIcon: View {
    @Bindable var state: MixerState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: Self.image(
            symbol: state.isConnected && state.masterMuted ? "speaker.slash.fill" : "slider.vertical.3",
            dimmed: !state.isConnected
        ))
        .onAppear { AppController.shared.openWindowAction = openWindow }
    }

    /// The menu bar renders only an image's alpha (template images), so
    /// SwiftUI's `.opacity` has no effect there; dimming has to be baked
    /// into the image itself.
    private static func image(symbol: String, dimmed: Bool) -> NSImage {
        // Semibold: at regular weight the thin slider strokes look grey
        // beside the system's own status icons.
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Scarlett MixControl")?
            .withSymbolConfiguration(config) else { return NSImage() }
        guard dimmed else {
            base.isTemplate = true
            return base
        }
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.4)
            return true
        }
        image.isTemplate = true
        // Keep the symbol's metrics so the icon doesn't shift when it dims.
        image.alignmentRect = base.alignmentRect
        image.accessibilityDescription = base.accessibilityDescription
        return image
    }
}

// MARK: - MenuBarPanel

/// Compact controls shown when the menu bar icon is clicked: output volumes,
/// mutes and meters, preset recall, Mute all.  Meters are polled only while
/// the panel is open — the main window is a click away for everything else.
@MainActor
struct MenuBarPanel: View {
    @Bindable var state: MixerState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.divider)
            if state.isConnected {
                outputs
                Divider().overlay(Theme.divider)
                MenuBarPresetRow(state: state)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                Text(disconnectedText)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 18)
            }
            Divider().overlay(Theme.divider)
            footer
        }
        .frame(width: 300)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
        .background(WindowAccessor { AppController.shared.attachPanelWindow($0) })
    }

    private var header: some View {
        HStack {
            Group {
                if state.isConnected {
                    Text(state.profile.modelName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    + Text(" (1st Gen)")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text("Scarlett MixControl")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .lineLimit(1)
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(state.isConnected ? "Connected" : "No device")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusColor: Color {
        switch state.connection {
        case .connected:    return Theme.success
        case .waiting:      return .orange
        case .disconnected: return Theme.failure
        case .unsupported:  return .yellow
        }
    }

    private var disconnectedText: String {
        switch state.connection {
        case .unsupported(let p): return "\(p.displayName) isn't supported."
        default:                  return "Waiting for a Scarlett to be connected…"
        }
    }

    @ViewBuilder
    private var outputs: some View {
        let groups = state.menuBarOutputGroups
        if groups.isEmpty {
            Text("No outputs shown. Pick some under Mixer → Outputs → Show in menu bar.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        } else {
            VStack(spacing: 10) {
                ForEach(groups, id: \.label) { group in
                    MenuBarOutputRow(state: state, label: group.label, outputs: group.outputs)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            MasterMuteButton(state: state)
                .disabled(!state.isConnected)
            Spacer()
            Button {
                AppController.shared.showMainWindow()
            } label: {
                Pill(icon: "macwindow", title: "Open Mixer")
            }
            .buttonStyle(.pill)
            .fixedSize()

            Menu {
                Button("Settings…") { AppController.shared.showSettings(openSettings) }
                if let update = UpdateChecker.shared.availableUpdate {
                    Link("Update available: v\(update.version)…", destination: update.url)
                }
                Divider()
                Button("Quit Scarlett MixControl") { AppController.shared.quit() }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 26, height: 22)
                    .background(Theme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: PillSize.toolbar.cornerRadius))
                    .updateDot()
            }
            .menuStyle(.button)
            .buttonStyle(.pill)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings and Quit")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Output row

/// One output pair: name, a mute toggle for both sides, and a horizontal
/// fader on the same dB law as the mixer's output strips.
@MainActor
private struct MenuBarOutputRow: View {
    @Bindable var state: MixerState
    let label: String
    let outputs: [PhysicalOutput]

    private var leftWValue: UInt16 { outputs.first?.wValue ?? 0 }

    /// The 18i20's Monitor level belongs to its front-panel knob; the
    /// fader only mirrors it (as in the mixer's Monitor strip).
    private var mirrorsHardwarePot: Bool {
        leftWValue == state.monitorPairLeftWValue && state.profile.hasHardwareMonitorControls
    }

    private var displayedDb: Double {
        if mirrorsHardwarePot, let hw = state.hwMonitor {
            return max(DbAxis.off, hw.potAttenuationDb)
        }
        return state.pairAtten(leftWValue: leftWValue)
    }

    /// Muted when every side is — the button then unmutes them all.
    private var muted: Bool {
        outputs.allSatisfy { state.outputMuted($0.wValue) }
    }

    /// The front-panel MUTE / DIM buttons (18i20 Monitor only), which the
    /// app can't override — shown as a tag so a normal-looking level
    /// doesn't mislead.
    private var hardwareTag: String? {
        guard mirrorsHardwarePot, let hw = state.hwMonitor else { return nil }
        if hw.mute { return "HW mute" }
        if hw.dim { return "Dim" }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .frame(width: 62, alignment: .leading)

            Button {
                let target = !muted
                for out in outputs { state.userSetOutputMute(wValue: out.wValue, muted: target) }
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(muted ? .white : Theme.textSecondary)
                    .frame(width: 24, height: 20)
                    .background(muted ? Theme.muteActive : Theme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.pill)
            .help(muted ? "Unmute \(label)" : "Mute \(label)")
            .accessibilityLabel(muted ? "Unmute \(label)" : "Mute \(label)")

            VStack(spacing: 1) {
                if mirrorsHardwarePot {
                    HorizontalFader(db: .constant(displayedDb), label: label)
                        .allowsHitTesting(false)
                } else {
                    HorizontalFader(db: Binding(
                        get: { state.pairAtten(leftWValue: leftWValue) },
                        set: { state.userSetPairAtten(leftWValue: leftWValue, db: $0) }
                    ), label: label)
                    .contextMenu {
                        Button("Reset to 0 dB") {
                            state.userSetPairAtten(leftWValue: leftWValue, db: 0)
                        }
                    }
                }
                PanelMeter(state: state, outputs: outputs)
                    .padding(.horizontal, DbAxis.inset)
            }

            Group {
                if let hardwareTag {
                    Text(hardwareTag)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.soloActive)
                } else {
                    Text(DbAxis.format(displayedDb))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(muted ? Theme.textSecondary.opacity(0.6) : Theme.textSecondary)
                }
            }
            .lineLimit(1)
            .frame(width: 42, alignment: .trailing)
        }
        .opacity(muted ? 0.75 : 1)
        // On the row: the read-only fader can't be hovered.
        .help(mirrorsHardwarePot ? "Monitor level is set by the front-panel knob on this device." : "")
    }
}

// MARK: - Meter

/// Thin horizontal meter per side of an output pair, showing the level of
/// whatever is routed to it — before the output's volume and mute, as on
/// the mixer's output strips.  Its own view, so the 12 Hz meter updates
/// redraw just the bars rather than the whole row.
@MainActor
private struct PanelMeter: View {
    @Bindable var state: MixerState
    let outputs: [PhysicalOutput]

    var body: some View {
        VStack(spacing: 1) {
            ForEach(outputs, id: \.wValue) { out in
                let source = state.routes[out.wValue] ?? .off
                Bar(db: state.peaks.level(for: source, profile: state.profile),
                    peakDb: state.peaksHeld.level(for: source, profile: state.profile))
            }
        }
        .accessibilityHidden(true)
    }

    private struct Bar: View {
        let db: Double
        let peakDb: Double
        private let floor = DbAxis.meterFloor

        /// Position of a level along the bar, 0 at the floor to 1 at 0 dBFS.
        private func fraction(_ db: Double) -> CGFloat {
            guard db.isFinite else { return 0 }
            return CGFloat(min(max((db - floor) / -floor, 0), 1))
        }

        var body: some View {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.faderTrack)
                    // Colour stops at the same levels as the mixer's meters.
                    Rectangle()
                        .fill(LinearGradient(
                            stops: [
                                .init(color: Theme.meterLow,  location: 0),
                                .init(color: Theme.meterLow,  location: fraction(-24)),
                                .init(color: Theme.meterMid,  location: fraction(-18)),
                                .init(color: Theme.meterMid,  location: fraction(-12)),
                                .init(color: Theme.meterHigh, location: fraction(-6)),
                                .init(color: Theme.meterHigh, location: 1),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: width * fraction(db))
                        }
                    if peakDb > floor {
                        Rectangle()
                            .fill(Theme.textPrimary)
                            .frame(width: 1.5)
                            .offset(x: width * fraction(peakDb) - 0.75)
                    }
                }
            }
            .frame(height: 2)
            .clipShape(RoundedRectangle(cornerRadius: 1))
        }
    }
}

// MARK: - Horizontal fader

/// Horizontal counterpart of `VerticalFader` on the attenuation axis: 0 dB
/// at the right end, off at the left.  Drags move the level relative to
/// where it was — unlike the mixer's faders a click doesn't jump to the
/// pointer, so a stray click in a quick-access panel can't throw the
/// monitors to 0 dB.
private struct HorizontalFader: View {
    @Binding var db: Double
    /// Output name, for VoiceOver.
    let label: String
    private let axis = DbAxis.attenuation
    private let knob: CGFloat = 14
    /// Knob position when the current drag began.
    @State private var dragStartX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            // `DbAxis` measures from the top of a column; the right end of
            // this one is the column's top.
            let x = width - axis.y(db, height: width)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.faderTrack)
                    .frame(height: 4)
                    .padding(.horizontal, DbAxis.inset)
                Capsule().fill(Theme.faderTrackFill)
                    .frame(width: max(0, x - DbAxis.inset), height: 4)
                    .offset(x: DbAxis.inset)
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.88), Theme.faderKnob],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: knob, height: knob)
                    .shadow(color: Theme.faderKnobShadow, radius: 1.5, y: 1)
                    .offset(x: x - knob / 2)
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        let start = dragStartX ?? x
                        dragStartX = start
                        db = axis.db(atY: width - (start + drag.translation.width), height: width)
                    }
                    .onEnded { _ in dragStartX = nil }
            )
        }
        .frame(height: 20)
        .accessibilityElement()
        .accessibilityLabel("\(label) volume")
        .accessibilityValue(db <= DbAxis.off ? "off" : "\(DbAxis.format(db)) dB")
        .accessibilityAdjustableAction { direction in
            // One dB per step, down into off below the axis' last mark.
            switch direction {
            case .increment: db = min(axis.top, db <= DbAxis.off ? DbAxis.meterFloor : db + 1)
            case .decrement: db = db - 1 < DbAxis.meterFloor ? DbAxis.off : db - 1
            @unknown default: break
            }
        }
    }
}

// MARK: - Presets

/// Preset recall: a menu of this device's presets, titled with the one
/// loaded and tagged once it's modified.  Loading never changes output
/// volumes (presets don't store them), so it's safe from here.
@MainActor
private struct MenuBarPresetRow: View {
    @Bindable var state: MixerState
    /// Result of the last load; `detail` (the error) is the tooltip.
    @State private var status: (ok: Bool, detail: String)?
    @State private var statusID = 0

    private var presets: [ScarlettPreset] {
        state.presets
            .filter { state.effectiveProductID(for: $0) == state.profile.productID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Preset")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 62, alignment: .leading)

            Menu {
                ForEach(presets) { preset in
                    // A checkmark on the one that's loaded, as a picker would.
                    Toggle(preset.name, isOn: Binding(
                        get: { state.loadedPreset?.source == .preset(preset.id) },
                        set: { _ in load(preset) }
                    ))
                }
            } label: {
                HStack(spacing: 4) {
                    Text(menuTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(width: 130)
                .background(Theme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            // A button-style menu draws the label as-is (as the mixer's
            // Outputs pill does); `.borderlessButton` would drop its fill.
            .menuStyle(.button)
            .buttonStyle(.pill)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(presets.isEmpty)

            if let status {
                Label(status.ok ? "Loaded" : "Failed", systemImage: status.ok ? "checkmark" : "xmark")
                    .font(.caption)
                    .foregroundStyle(status.ok ? Theme.success : Theme.failure)
                    .lineLimit(1)
                    .help(status.detail)
            } else if state.loadedPresetName != nil && state.loadedPresetModified {
                LoadedBadge(modified: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// The loaded preset (or snapshot / factory default), else a prompt.
    private var menuTitle: String {
        if let name = state.loadedPresetName { return name }
        return presets.isEmpty ? "No presets" : "Load…"
    }

    private func load(_ preset: ScarlettPreset) {
        do {
            try state.userLoadPreset(preset)
            show(ok: true, "Loaded \(preset.name)")
        } catch {
            show(ok: false, error.localizedDescription)
        }
    }

    /// Show a result for a few seconds; a newer one replaces it.
    private func show(ok: Bool, _ detail: String) {
        statusID += 1
        let id = statusID
        status = (ok, detail)
        Task {
            try? await Task.sleep(for: .seconds(3))
            if statusID == id { status = nil }
        }
    }
}
