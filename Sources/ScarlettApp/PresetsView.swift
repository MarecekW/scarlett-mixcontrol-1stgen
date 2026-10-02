import SwiftUI
import ScarlettCore

@MainActor
struct PresetsView: View {
    @Bindable var state: MixerState
    @State private var newPresetName: String = ""
    @State private var confirmDelete: ScarlettPreset?
    @State private var confirmFactoryDefault = false
    @State private var loadErrorMessage: String?
    /// Preset whose name is being edited inline, and the edit buffer.
    @State private var renamingID: UUID?
    @State private var renameText: String = ""
    /// Keyed by preset so one row's field losing focus can't be mistaken
    /// for the next row's.
    @FocusState private var focusedRenameID: UUID?

    /// Row buttons sit on a `panelRaised` row, so they need a lighter fill.
    private static let rowButtonFill = Color(white: 0.27)

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        // Preset save/load both touch the device (push routes + matrix), so
        // when there's no device the page is gated the same way Mixer and
        // Routing are.
        ConnectionOverlay(state: state) {
            presetsContent
        }
    }

    private var presetsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                // Two equal cards side by side, as tall as the taller one.
                HStack(alignment: .top, spacing: 18) {
                    Panel(title: "Save current state") {
                        cardContent {
                            saveRow
                            Text("Saves routing, the matrix and channel names, but not output volumes, so loading a preset never changes your listening level. Saving under an existing name replaces that preset.")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .help("Captures output routing, matrix sources / gains / pans / mutes / solos, channel names, stereo-link state, and which bus is in view. Output volumes (Monitor, Phones) are not included.")
                        }
                    }
                    Panel(title: "Snapshot files") {
                        cardContent {
                            HStack(spacing: 8) {
                                Button { exportSnapshot(state: state) } label: {
                                    Pill(icon: "square.and.arrow.down", title: "Save snapshot…", size: .row)
                                }
                                .buttonStyle(.pill)
                                .fixedSize()
                                Button { importSnapshot(state: state) } label: {
                                    Pill(icon: "folder", title: "Open snapshot…", size: .row)
                                }
                                .buttonStyle(.pill)
                                .fixedSize()
                            }
                            Text("Back up the current state to a .scmx file or move it to another Mac. With the Dock icon shown, also in the File menu (⌘S / ⌘O).")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Panel(title: "Saved presets") {
                    VStack(spacing: 4) {
                        factoryDefaultRow
                        ForEach(state.presets.sorted(by: { $0.createdAt > $1.createdAt })) { preset in
                            presetRow(preset)
                        }
                    }
                    if state.presets.isEmpty {
                        Text("No saved presets yet — save one above.")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        // Clicking empty space ends an in-progress rename (via focus loss).
        .onTapGesture { focusedRenameID = nil }
        .background(Theme.background)
        .confirmationDialog(
            "Delete preset?",
            isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let p = confirmDelete {
                Button("Delete \"\(p.name)\"", role: .destructive) {
                    state.userDeletePreset(p)
                    confirmDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        }
        .alert(
            "Couldn’t load preset",
            isPresented: Binding(
                get: { loadErrorMessage != nil },
                set: { if !$0 { loadErrorMessage = nil } }
            )
        ) {
            Button("OK") { loadErrorMessage = nil }
        } message: {
            Text(loadErrorMessage ?? "Unknown error")
        }
        .resetConfirmation(isPresented: $confirmFactoryDefault, state: state,
                           title: "Load \(MixerState.factoryDefaultName)?", confirm: "Load")
    }

    /// A card's body, stretched to fill its half of the row so both cards
    /// share a width and height.
    private func cardContent<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Presets").font(.title2).bold().foregroundStyle(Theme.textPrimary)
            Spacer()
            if let name = state.loadedPresetName {
                HStack(spacing: 6) {
                    Text("Current: ").foregroundStyle(Theme.textSecondary)
                        + Text(name).foregroundStyle(Theme.textPrimary)
                    LoadedBadge(modified: state.loadedPresetModified)
                }
                .font(.caption)
                .lineLimit(1)
                Text("·").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Text("\(state.presets.count) saved")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private var saveRow: some View {
        HStack(spacing: 10) {
            TextField("Preset name", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { savePreset() }

            Button {
                savePreset()
            } label: {
                Pill(icon: "bookmark.fill", title: "Save",
                     fill: Theme.muteActive, foreground: .white, size: .row)
            }
            .buttonStyle(.pill)
            .disabled(ScarlettPreset.normalizedName(newPresetName).isEmpty)
        }
    }

    private func savePreset() {
        let name = ScarlettPreset.normalizedName(newPresetName)
        guard !name.isEmpty else { return }
        state.userSavePreset(name: name)
        newPresetName = ""
    }

    private func startRename(_ preset: ScarlettPreset) {
        guard renamingID != preset.id else { return }
        // Switching rows counts as clicking away: apply the pending name.
        if let id = renamingID, let current = state.presets.first(where: { $0.id == id }) {
            state.userRenamePreset(current, to: renameText)
        }
        renameText = preset.name
        renamingID = preset.id
        // Focus after the TextField exists; setting it in the same update
        // is dropped.
        DispatchQueue.main.async { focusedRenameID = preset.id }
    }

    /// Enter: apply the new name.  An empty or unchanged name just ends the
    /// edit; a name another preset already uses keeps the field open.
    private func submitRename(_ preset: ScarlettPreset) {
        let name = ScarlettPreset.normalizedName(renameText)
        if name.isEmpty || name == preset.name || state.userRenamePreset(preset, to: name) {
            renamingID = nil
        } else {
            focusedRenameID = preset.id
        }
    }

    /// Focus left the field (click elsewhere): apply the name if it's valid,
    /// otherwise drop the edit.
    private func endRename(_ preset: ScarlettPreset) {
        guard renamingID == preset.id else { return }
        state.userRenamePreset(preset, to: renameText)
        renamingID = nil
    }

    @ViewBuilder
    private func presetNameField(_ preset: ScarlettPreset) -> some View {
        let taken = state.presetNameTaken(renameText, excluding: preset)
        VStack(alignment: .leading, spacing: 2) {
            TextField("Preset name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .focused($focusedRenameID, equals: preset.id)
                .onSubmit { submitRename(preset) }
                .onExitCommand { renamingID = nil }
                .onChange(of: focusedRenameID) { old, new in
                    if old == preset.id, new != preset.id { endRename(preset) }
                }
            Text(taken ? "Another preset for this device already uses that name" : "Enter to rename · Esc to cancel")
                .font(.caption2)
                .foregroundStyle(taken ? Theme.failure : Theme.textSecondary)
        }
    }

    private func isLoaded(_ preset: ScarlettPreset) -> Bool {
        state.loadedPreset?.source == .preset(preset.id)
    }

    /// The built-in reset, always first in the list.  Can't be renamed or
    /// deleted, and asks before it overwrites the current mix.
    private var factoryDefaultRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(MixerState.factoryDefaultName)
                        .font(.subheadline.bold()).foregroundStyle(Theme.textPrimary)
                    if state.loadedPreset?.source == .factoryDefault {
                        LoadedBadge(modified: state.loadedPresetModified)
                    }
                }
                Text("Built in · the default routing and mix for \(state.profile.modelName)")
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Button {
                    confirmFactoryDefault = true
                } label: {
                    // As wide as the other rows' Load (sized for "Loaded").
                    ZStack {
                        Pill(icon: "checkmark", title: "Loaded", size: .row, fillsWidth: true).hidden()
                        Pill(title: "Load", fill: Self.rowButtonFill, foreground: Theme.textPrimary,
                             size: .row, fillsWidth: true)
                    }
                }
                .buttonStyle(.pill)
                .fixedSize()
                // Where the other rows have their delete button.
                Color.clear.frame(width: 24, height: 22)
            }
        }
        .padding(10)
        .background(Theme.panelRaised.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Theme.divider, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        )
    }

    private func presetRow(_ preset: ScarlettPreset) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if renamingID == preset.id {
                presetNameField(preset)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(preset.name).font(.subheadline.bold()).foregroundStyle(Theme.textPrimary)
                        if isLoaded(preset) {
                            LoadedBadge(modified: state.loadedPresetModified)
                        }
                    }
                    Text(Self.dateFormatter.string(from: preset.createdAt))
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                    Text(state.presetDeviceLabel(preset))
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                }
                .help("Click to rename")
            }
            Spacer()
            HStack(spacing: 4) {
                if isLoaded(preset) && state.loadedPresetModified {
                    Button {
                        state.userUpdatePreset(preset)
                    } label: {
                        Pill(icon: "square.and.arrow.down", title: "Save modified",
                             fill: Theme.muteActive, foreground: .white, size: .row)
                    }
                    .buttonStyle(.pill)
                    .fixedSize()
                    .help("Save the current state into this preset")
                }
                FeedbackButton(action: {
                    do {
                        try state.userLoadPreset(preset)
                        return true
                    } catch {
                        loadErrorMessage = error.localizedDescription
                        return false
                    }
                }) { phase in
                    FeedbackPill(phase: phase, title: "Load", doneTitle: "Loaded",
                                 fill: Self.rowButtonFill, foreground: Theme.textPrimary, size: .row)
                }
                .buttonStyle(.pill)
                .fixedSize()

                Button {
                    confirmDelete = preset
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .frame(width: 24, height: 22)
                        .background(Self.rowButtonFill)
                        .foregroundStyle(Theme.failure)
                        .clipShape(RoundedRectangle(cornerRadius: PillSize.row.cornerRadius))
                }
                .buttonStyle(.pill)
                .help("Delete preset")
                .accessibilityLabel("Delete preset \(preset.name)")
            }
        }
        .padding(10)
        .contentShape(Rectangle())
        .onTapGesture { startRename(preset) }
        .background(Theme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

/// "Loaded" next to the preset that's on the device, "Modified" once the
/// routing or matrix has changed since.
struct LoadedBadge: View {
    let modified: Bool

    var body: some View {
        let color = modified ? Theme.soloActive : Theme.success
        Text(modified ? "Modified" : "Loaded")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(Theme.statusFillOpacity))
            .clipShape(Capsule())
            .help(modified ? "Changed since it was loaded" : "On the device now, unchanged")
    }
}
