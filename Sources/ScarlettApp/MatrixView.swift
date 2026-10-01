import SwiftUI
import ScarlettCore

/// The matrix mixer view — Control 2 style.
///
/// Top bar: bus tabs (Mix M1..Mn).
/// Below: horizontally scrolling row of `ChannelStrip`s, one per matrix
/// channel we expose.  We show at least 14 (the 8i6-era default), and expand
/// to cover every physical input on devices that have more — the 18i6/18i8/
/// 18i20 have 18 real inputs, so all 18 matrix slots are useful there.
@MainActor
struct MatrixMixerView: View {
    @Bindable var state: MixerState
    private var visibleChannels: Range<Int> {
        let physicalInputs = state.profile.sources.filter {
            $0.category == .analog || $0.category == .digital
        }.count
        return 0..<min(state.profile.matrixInputCount, max(14, physicalInputs))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            busTabs
            strips
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Mixer").font(.title3).bold().foregroundStyle(Theme.textPrimary)
            Spacer()
            Text("Pick a bus tab to set its per-channel gains. Use the strips' source pickers to wire signals in.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 320)
        }
    }

    private var busTabs: some View {
        HStack(spacing: 4) {
            ForEach(state.matrixBuses) { bus in
                let selected = state.selectedBus == bus
                Button {
                    state.selectedBus = bus
                } label: {
                    Text(bus.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 60, height: 28)
                        .background(selected ? Theme.muteActive : Theme.panelRaised)
                        .foregroundStyle(selected ? .white : Theme.textSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .contextMenu { copyMixMenuItems(targetBus: bus) }
            }
            Spacer()
            FeedbackButton(action: { state.clearMaxPeaks(); return true }) { phase in
                FeedbackPill(phase: phase, icon: "arrow.counterclockwise",
                             title: "Clear peaks", doneTitle: "Cleared")
            }
            .buttonStyle(.pill)
            .fixedSize()
            .help("Reset the red max-peak tick on every strip.")

            masterMuteButton
            .help("Mute every output bus on the device.")

            FeedbackButton(action: { await state.saveToFlash() }) { phase in
                FeedbackPill(phase: phase, icon: "internaldrive",
                             title: "Save to hardware", doneTitle: "Saved")
            }
            .buttonStyle(.pill)
            .fixedSize()
            .disabled(!state.isConnected)
            .help("Persist current settings to device flash so they survive a power cycle.")

            outputsMenu
                .help("Choose which output pairs are pinned as strips on the right.")
        }
    }

    /// Menu of output pairs — check to pin a pair's strip in the mixer.
    private var outputsMenu: some View {
        Menu {
            ForEach(state.physicalOutputGroups, id: \.label) { group in
                Toggle(isOn: Binding(
                    get: { state.visiblePairLabels.contains(group.label) },
                    set: { _ in state.userToggleOutputPairVisible(label: group.label) }
                )) {
                    Text(group.label)
                }
            }
        } label: {
            // The chevron marks this as a menu rather than an action.
            Pill(icon: "rectangle.split.3x1", title: "Outputs", trailingIcon: "chevron.down")
        }
        // A `.borderlessButton` menu doesn't draw the label's background
        // (`ThemedMenuPicker` relies on that for its flat look); a
        // button-style menu draws the pill as-is.
        .menuStyle(.button)
        .buttonStyle(.pill)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Context-menu items for a bus tab — copy this pair's settings to one
    /// of the other two pairs.  Right-click any bus tab to access.
    @ViewBuilder
    private func copyMixMenuItems(targetBus: MixBus) -> some View {
        let sourcePair = targetBus.stereoPairIndex ?? 0
        let pairLabel: (Int) -> String = { p in "M\(p*2 + 1)+M\(p*2 + 2)" }
        ForEach(0..<state.stereoPairCount, id: \.self) { dest in
            if dest != sourcePair {
                Button("Copy \(pairLabel(sourcePair)) → \(pairLabel(dest))") {
                    state.userCopyMixPair(from: sourcePair, to: dest)
                }
            }
        }
    }

    /// Toggles the master mute.  The label morphs between "Mute all" and
    /// "Master muted".  The toggle runs inside `withAnimation` so the whole
    /// toolbar re-lays out in step (width grows, neighbours slide); the icon
    /// rides the leading edge and crossfades in place, and the two labels
    /// are separate views that crossfade.
    private var masterMuteButton: some View {
        let muted = state.masterMuted
        return Button {
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
    }

    private var strips: some View {
        HStack(alignment: .top, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(visibleChannels, id: \.self) { ch in
                        ChannelStrip(channel: ch, state: state)
                    }
                }
                .padding(.vertical, 4)
            }
            if state.hasPinnedDawReturn {
                PinnedDawStrip(state: state)
            }
            PinnedMasterStrip(state: state)
        }
    }
}
