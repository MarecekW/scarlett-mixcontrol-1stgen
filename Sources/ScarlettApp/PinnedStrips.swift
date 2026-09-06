import SwiftUI
import ScarlettCore

// MARK: - PinnedDawStrip

/// Pinned DAW return strip.  Drives matrix channels 14 + 15 — reserved at
/// init for this purpose, sourced from DAW 1 / DAW 2, panned hard-left /
/// hard-right, and linked so this single fader controls both.
@MainActor
struct PinnedDawStrip: View {
    @Bindable var state: MixerState

    private var leftCh: Int  { MixerState.pinnedDawLeftChannel  }
    private var rightCh: Int { MixerState.pinnedDawRightChannel }

    var body: some View {
        VStack(spacing: StripLayout.vSpacing) {
            header
            // No input switch on a DAW return.
            Color.clear.frame(height: StripLayout.switchRowHeight)
            // No pan on this strip — DAW pair is hard-panned by design.
            Color.clear.frame(height: StripLayout.panRowHeight)
            fader
            peakReadout
            controls
        }
        .frame(width: StripLayout.width)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var header: some View {
        VStack(spacing: 3) {
            Text("DAW")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Playback 1+2")
                .font(.system(size: 9))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Rectangle()
                .fill(Theme.accentPlayback)
                .frame(height: 2)
                .padding(.horizontal, 2)
        }
        .frame(height: StripLayout.headerHeight, alignment: .bottom)
    }

    private var fader: some View {
        let pair = MixerState.pairIndex(of: state.selectedBus)
        let level = state.mixerLevels[leftCh][pair]
        let isMuted = state.mixerMutes[leftCh]

        return HStack(alignment: .center, spacing: 4) {
            VerticalFader(db: Binding(
                get: { level },
                set: { state.userSetMixerLevel(channel: leftCh, pair: pair, level: $0) }
            ))
            .opacity(isMuted ? 0.4 : 1.0)
            .contextMenu {
                Button("Reset fader to 0 dB") {
                    state.userSetMixerLevel(channel: leftCh, pair: pair, level: 0)
                }
            }

            VStack(spacing: 1) {
                StripMeter(state: state, source: .daw1, profile: state.profile, height: 220)
                Text("L").font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }
            VStack(spacing: 1) {
                StripMeter(state: state, source: .daw2, profile: state.profile, height: 220)
                Text("R").font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }

            DbScale()
        }
        .frame(height: StripLayout.faderHeight)
        .overlay(alignment: .topTrailing) {
            Text(formatDb(level))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(isMuted ? Theme.muteActive : Theme.textSecondary)
                .padding(.top, -16)
        }
    }

    private var peakReadout: some View {
        let peakL = StripMeter.level(from: state.peaksHeld, source: .daw1, profile: state.profile)
        let peakR = StripMeter.level(from: state.peaksHeld, source: .daw2, profile: state.profile)
        let maxL  = StripMeter.level(from: state.peaksMax,  source: .daw1, profile: state.profile)
        let maxR  = StripMeter.level(from: state.peaksMax,  source: .daw2, profile: state.profile)
        let peak = max(peakL, peakR)
        let max_ = max(maxL, maxR)
        return VStack(spacing: 1) {
            Text(formatPeak("Pk", peak))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            Button {
                state.clearMaxPeak(forSource: .daw1)
                state.clearMaxPeak(forSource: .daw2)
            } label: {
                Text(formatPeak("Mx", max_))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.meterHigh)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click to reset DAW 1+2 max peaks")
        }
        .frame(height: StripLayout.peakReadoutHeight)
    }

    private var controls: some View {
        let isMuted = state.mixerMutes[leftCh]
        return HStack(spacing: 3) {
            Spacer(minLength: 0)
            StripButton(letter: "M", active: isMuted, activeColor: Theme.muteActive) {
                let newValue = !isMuted
                state.userSetMixerMute(channel: leftCh,  muted: newValue)
                state.userSetMixerMute(channel: rightCh, muted: newValue)
            }
            Spacer(minLength: 0)
        }
        .frame(height: StripLayout.controlsHeight)
    }

    private func formatDb(_ db: Double) -> String {
        if db <= -60 { return "−∞" }
        let r = Int(db.rounded())
        return r > 0 ? "+\(r)" : "\(r)"
    }

    private func formatPeak(_ label: String, _ db: Double) -> String {
        if !db.isFinite || db <= -60 { return "\(label) −∞" }
        return String(format: "%@ %5.1f", label, db)
    }
}

// MARK: - PinnedMasterStrip

/// The pinned output-pair strips — one per pair the user has chosen to show
/// (Outputs menu in the mixer header).  Driven entirely by the device
/// profile, so an 18i20 shows "Line 3+4" where an 8i6 shows "Phones".
/// Same height as channel and DAW strips so the whole row lines up.
@MainActor
struct PinnedMasterStrip: View {
    @Bindable var state: MixerState

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(state.visibleOutputGroups, id: \.label) { group in
                OutputStrip(
                    state: state,
                    title: group.label,
                    outputs: group.outputs,
                    // Dim only applies to the Monitor pair (the first one).
                    showDim: group.outputs.first?.wValue == state.monitorPairLeftWValue
                )
            }
        }
    }
}

// MARK: - OutputStrip

/// One vertical strip for a physical output pair (Monitor, Phones, Line
/// N+M, S/PDIF, …).  Its meters follow whatever's currently routed to that
/// physical output — if the left output is routed from DAW 1 the meter
/// shows DAW 1's level; if it's routed from Mix M1 the meter shows M1's.
@MainActor
struct OutputStrip: View {
    @Bindable var state: MixerState
    let title: String
    let outputs: [PhysicalOutput]
    let showDim: Bool

    private var leftWValue: UInt16 { outputs.first?.wValue ?? 0 }
    private var rightOutput: PhysicalOutput? { outputs.count > 1 ? outputs[1] : nil }

    /// Digital pairs (S/PDIF, ADAT) have no functional gain/mute stage —
    /// they get meters only, at fixed level.
    private var hasGainStage: Bool { state.profile.hasGainStage(wValue: leftWValue) }

    /// True for the Monitor pair on a device with a hardware monitor
    /// section (18i20): its level is owned by the front-panel knob, so the
    /// fader is a read-only mirror of the pot.
    private var mirrorsHardwarePot: Bool {
        showDim && state.profile.hasHardwareMonitorControls
    }

    /// The dB value the fader should show: the hardware pot when mirroring,
    /// otherwise the software pair attenuation.
    private var displayedDb: Double {
        if mirrorsHardwarePot, let hw = state.hwMonitor {
            return max(-60, hw.potAttenuationDb)
        }
        return state.pairAtten(leftWValue: leftWValue)
    }

    private var subtitle: String {
        "Out " + outputs.map { "\($0.wValue + 1)" }.joined(separator: "+")
    }

    private var atten: Binding<Double> {
        Binding(
            get: { state.pairAtten(leftWValue: leftWValue) },
            set: { state.userSetPairAtten(leftWValue: leftWValue, db: $0) }
        )
    }

    /// Source feeding the L/R output right now (per the router).
    /// Defaults to .off when no route has been set yet.
    private var leftSource:  MixBus { state.route(forOutput: leftWValue) }
    private var rightSource: MixBus {
        rightOutput.map { state.route(forOutput: $0.wValue) } ?? .off
    }

    var body: some View {
        VStack(spacing: StripLayout.vSpacing) {
            header
            Color.clear.frame(height: StripLayout.switchRowHeight)
            Color.clear.frame(height: StripLayout.panRowHeight)
            fader
            peakReadout
            controls
        }
        .frame(width: StripLayout.width)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var header: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(subtitle)
                .font(.system(size: 9))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Rectangle()
                .fill(Theme.textSecondary.opacity(0.5))
                .frame(height: 2)
                .padding(.horizontal, 2)
        }
        .frame(height: StripLayout.headerHeight, alignment: .bottom)
    }

    private var fader: some View {
        HStack(alignment: .center, spacing: 4) {
            if mirrorsHardwarePot {
                // Level is owned by the front-panel knob; the fader just
                // tracks it. Not draggable — turning the knob moves it.
                VerticalFader(db: Binding(get: { displayedDb }, set: { _ in }),
                              dbRange: -60...0)
                    .allowsHitTesting(false)
                    .help("Monitor level is set by the front-panel knob on this device — the fader mirrors it.")
            } else if hasGainStage {
                VerticalFader(db: atten, dbRange: -60...0)
                    .contextMenu {
                        Button("Reset to 0 dB") {
                            state.userSetPairAtten(leftWValue: leftWValue, db: 0)
                        }
                    }
            }

            RoutedMeter(state: state, source: leftSource, profile: state.profile)
            if rightOutput != nil {
                RoutedMeter(state: state, source: rightSource, profile: state.profile)
            }

            DbScale(
                dbRange: -60...0,
                marks: [0, -6, -12, -18, -24, -30, -36, -48, -60]
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: StripLayout.faderHeight)
        .overlay(alignment: .topTrailing) {
            if hasGainStage {
                Text("\(Int(displayedDb))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, -16)
            }
        }
    }

    /// Pk / Mx based on the louder of the two currently-routed sources.
    private var peakReadout: some View {
        let peakL = RoutedMeter.level(from: state.peaksHeld, source: leftSource, profile: state.profile)
        let peakR = RoutedMeter.level(from: state.peaksHeld, source: rightSource, profile: state.profile)
        let maxL  = RoutedMeter.level(from: state.peaksMax,  source: leftSource, profile: state.profile)
        let maxR  = RoutedMeter.level(from: state.peaksMax,  source: rightSource, profile: state.profile)
        let peak = max(peakL, peakR)
        let max_ = max(maxL, maxR)
        return VStack(spacing: 1) {
            Text(formatPeak("Pk", peak))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            Button {
                state.clearMaxPeak(leftSource)
                state.clearMaxPeak(rightSource)
            } label: {
                Text(formatPeak("Mx", max_))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.meterHigh)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click to reset this output's max peaks")
        }
        .frame(height: StripLayout.peakReadoutHeight)
    }

    @ViewBuilder
    private var controls: some View {
        if hasGainStage {
            let leftMuted = state.outputMuted(leftWValue)
            let rightMuted = rightOutput.map { state.outputMuted($0.wValue) } ?? false
            HStack(spacing: 3) {
                Spacer(minLength: 0)
                StripButton(letter: rightOutput == nil ? "M" : "ML", active: leftMuted,
                            activeColor: Theme.muteActive) {
                    state.userSetOutputMute(wValue: leftWValue, muted: !leftMuted)
                }
                if let right = rightOutput {
                    StripButton(letter: "MR", active: rightMuted,
                                activeColor: Theme.muteActive) {
                        state.userSetOutputMute(wValue: right.wValue, muted: !rightMuted)
                    }
                }
                if showDim {
                    if state.profile.hasHardwareMonitorControls {
                        // 18i20: Dim and Mute live on the front panel — the
                        // app mirrors them read-only instead of offering a
                        // second, competing software Dim.
                        HWIndicator(label: "Dim",  active: state.hwMonitor?.dim ?? false)
                        // The 18i20's MUTE button lights red — match it.
                        HWIndicator(label: "Mute", active: state.hwMonitor?.mute ?? false,
                                    activeColor: Theme.meterHigh)
                    } else {
                        StripButton(letter: "Dim", active: state.dimEnabled,
                                    activeColor: Theme.soloActive) {
                            state.userToggleDim()
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: StripLayout.controlsHeight)
        } else if let mixIdx = leftSource.matrixIndex, mixIdx < state.profile.mixBusCount {
            // Digital pair fed from a mix — jump straight to that mix's
            // faders, which are the level control for this output.  (This is
            // what the original MixControl did: its output tabs showed the
            // feeding mix's faders, so digital outs "had faders" one hop
            // upstream.)
            Button {
                state.selectedBus = leftSource
            } label: {
                Text("\(leftSource.displayName) ▸")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.panelRaised)
                    .foregroundStyle(Theme.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .frame(height: StripLayout.controlsHeight)
            .help("This digital output plays its source at fixed level. It's fed from \(leftSource.displayName) — click to open that mix's faders, which set this output's level.")
        } else {
            // Digital pair fed directly (DAW/input) — fixed level, nothing
            // to control here. Keep the row height so strips stay aligned.
            Text("fixed level")
                .font(.system(size: 8))
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
                .frame(height: StripLayout.controlsHeight)
                .help("""
                Digital outputs on this hardware have no volume or mute stage \
                — a directly-routed source always plays at full level (the \
                original MixControl had the same limitation; its output tabs \
                showed the feeding mix's faders). For level control, route \
                \(title) from a Mix bus in the Routing tab and put the source \
                through that mix — its faders then set this output's level.
                """)
        }
    }

    private func formatPeak(_ label: String, _ db: Double) -> String {
        if !db.isFinite || db <= -60 { return "\(label) −∞" }
        return String(format: "%@ %5.1f", label, db)
    }
}

// MARK: - HWIndicator

/// Read-only indicator lamp mirroring a hardware button (18i20 front-panel
/// DIM/MUTE).  Not clickable — the hardware owns the state.
struct HWIndicator: View {
    let label: String
    let active: Bool
    /// Lamp color when lit — matches the device's own LED color.
    var activeColor: Color = Theme.soloActive

    var body: some View {
        Text(label)
            .font(.system(size: 8, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(active ? activeColor : Theme.panelRaised.opacity(0.5))
            .foregroundStyle(active ? .white : Theme.textSecondary.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Theme.textSecondary.opacity(0.25), lineWidth: 0.5)
            )
            .help("\(label) is controlled by the front-panel button on this device — shown here read-only.")
    }
}

// MARK: - RoutedMeter

/// Vertical meter that looks up its source-meter slot dynamically based on
/// what `MixBus` source the user has routed to a given output. Isolates the
/// peak observations into its own view so 12-Hz updates only re-render this
/// little widget, not the whole output strip.
@MainActor
struct RoutedMeter: View {
    @Bindable var state: MixerState
    let source: MixBus
    let profile: DeviceProfile
    var height: CGFloat = 220

    var body: some View {
        let live = Self.level(from: state.peaks,    source: source, profile: profile)
        let held = Self.level(from: state.peaksHeld, source: source, profile: profile)
        let max_ = Self.level(from: state.peaksMax,  source: source, profile: profile)
        VerticalMeter(db: live, peakDb: held, maxPeakDb: max_, height: height)
    }

    static func level(from reading: PeakReading, source: MixBus, profile: DeviceProfile) -> Double {
        reading.level(for: source, profile: profile)
    }
}
