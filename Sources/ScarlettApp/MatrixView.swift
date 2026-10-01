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
            actionButton(icon: "arrow.counterclockwise", label: "Clear peaks") {
                state.clearMaxPeaks()
            }
            .help("Reset the red max-peak tick on every strip.")

            actionButton(
                icon: state.masterMuted ? "speaker.slash.fill" : "speaker.wave.2",
                label: state.masterMuted ? "Master muted" : "Mute all",
                active: state.masterMuted,
                activeColor: Theme.muteActive
            ) {
                state.userSetMasterMute(!state.masterMuted)
            }
            .help("Mute every output bus on the device.")

            actionButton(icon: "internaldrive", label: "Save to hardware") {
                state.saveToFlash()
            }
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
            HStack(spacing: 5) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 10, weight: .semibold))
                Text("Outputs")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.panelRaised)
            .foregroundStyle(Theme.textSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .menuStyle(.borderlessButton)
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

    private func actionButton(
        icon: String, label: String,
        active: Bool = false, activeColor: Color = Theme.muteActive,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(active ? activeColor : Theme.panelRaised)
            .foregroundStyle(active ? .white : Theme.textSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
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
