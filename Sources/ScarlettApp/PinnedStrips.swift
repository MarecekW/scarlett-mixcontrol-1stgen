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

/// Two vertical output strips (Monitor + Phones) side-by-side. Same height
/// as channel and DAW strips so the whole row lines up.
@MainActor
struct PinnedMasterStrip: View {
    @Bindable var state: MixerState

    /// Resolves a `pairLabel`'s wValue pair from the connected profile rather
    /// than assuming the 8i6's fixed 0/1/2/3 layout. The 18i20 has no
    /// "Phones" pairLabel at all — its headphone jacks are hardwired taps of
    /// Line 7/8 + Line 9/10 (see `DeviceProfile.scarlett18i20`) — so that
    /// strip is omitted for it below rather than pointing at the wrong pair.
    private static func wValues(in profile: DeviceProfile, pairLabel: String) -> (left: UInt16, right: UInt16)? {
        let outs = profile.physicalOutputs.filter { $0.pairLabel == pairLabel }
        guard let left = outs.first(where: \.isLeft), let right = outs.first(where: { !$0.isLeft }) else {
            return nil
        }
        return (left.wValue, right.wValue)
    }

    private var monitor: (left: UInt16, right: UInt16)? {
        Self.wValues(in: state.profile, pairLabel: "Monitor")
    }
    private var phones: (left: UInt16, right: UInt16)? {
        Self.wValues(in: state.profile, pairLabel: "Phones")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if let monitor {
                OutputStrip(
                    state: state,
                    title: "Monitor",
                    subtitle: "Out \(monitor.left + 1)+\(monitor.right + 1)",
                    atten: Binding(
                        get: { state.monitorAtten },
                        set: { state.userSetMonitorAtten($0) }
                    ),
                    leftWValue: monitor.left,
                    rightWValue: monitor.right,
                    leftMuted: state.monitorLMuted,
                    rightMuted: state.monitorRMuted,
                    toggleLeft: {
                        state.userSetSideMute(bus: .monitorLeft, muted: !state.monitorLMuted)
                    },
                    toggleRight: {
                        state.userSetSideMute(bus: .monitorRight, muted: !state.monitorRMuted)
                    },
                    showDim: true,
                    dimActive: state.dimEnabled,
                    toggleDim: { state.userToggleDim() }
                )
            }

            if let phones {
                OutputStrip(
                    state: state,
                    title: "Phones",
                    subtitle: "Out \(phones.left + 1)+\(phones.right + 1)",
                    atten: Binding(
                        get: { state.phonesAtten },
                        set: { state.userSetPhonesAtten($0) }
                    ),
                    leftWValue: phones.left,
                    rightWValue: phones.right,
                    leftMuted: state.phonesLMuted,
                    rightMuted: state.phonesRMuted,
                    toggleLeft: {
                        state.userSetSideMute(bus: .phonesLeft, muted: !state.phonesLMuted)
                    },
                    toggleRight: {
                        state.userSetSideMute(bus: .phonesRight, muted: !state.phonesRMuted)
                    },
                    showDim: false,
                    dimActive: false,
                    toggleDim: {}
                )
            }
        }
    }
}

// MARK: - OutputStrip

/// One vertical strip for an output pair (Monitor or Phones).
/// Its meters follow whatever's currently routed to that physical output —
/// if Monitor L is routed from DAW 1 the meter shows DAW 1's level; if
/// it's routed from Mix M1 the meter shows M1's level.
@MainActor
struct OutputStrip: View {
    @Bindable var state: MixerState
    let title: String
    let subtitle: String
    @Binding var atten: Double
    let leftWValue: UInt16
    let rightWValue: UInt16
    let leftMuted: Bool
    let rightMuted: Bool
    let toggleLeft: () -> Void
    let toggleRight: () -> Void
    let showDim: Bool
    let dimActive: Bool
    let toggleDim: () -> Void

    /// Source feeding the L/R output right now (per the router).
    /// Defaults to .off when no route has been set yet.
    private var leftSource:  MixBus { state.route(forOutput: leftWValue) }
    private var rightSource: MixBus { state.route(forOutput: rightWValue) }

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
            VerticalFader(db: $atten, dbRange: -60...0)
                .contextMenu { Button("Reset to 0 dB") { atten = 0 } }

            RoutedMeter(state: state, source: leftSource, profile: state.profile)
            RoutedMeter(state: state, source: rightSource, profile: state.profile)

            DbScale(
                dbRange: -60...0,
                marks: [0, -6, -12, -18, -24, -30, -36, -48, -60]
            )
        }
        .frame(height: StripLayout.faderHeight)
        .overlay(alignment: .topTrailing) {
            Text("\(Int(atten))")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, -16)
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

    private var controls: some View {
        HStack(spacing: 3) {
            Spacer(minLength: 0)
            StripButton(letter: "ML", active: leftMuted,
                        activeColor: Theme.muteActive, action: toggleLeft)
            StripButton(letter: "MR", active: rightMuted,
                        activeColor: Theme.muteActive, action: toggleRight)
            if showDim {
                StripButton(letter: "Dim", active: dimActive,
                            activeColor: Theme.soloActive, action: toggleDim)
            }
            Spacer(minLength: 0)
        }
        .frame(height: StripLayout.controlsHeight)
    }

    private func formatPeak(_ label: String, _ db: Double) -> String {
        if !db.isFinite || db <= -60 { return "\(label) −∞" }
        return String(format: "%@ %5.1f", label, db)
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
