import SwiftUI
import ScarlettCore

@MainActor
struct PresetsView: View {
    @Bindable var state: MixerState
    @State private var newPresetName: String = ""
    @State private var confirmDelete: ScarlettPreset?
    @State private var loadErrorMessage: String?
    /// Preset whose Load button briefly shows "Loaded" as confirmation.
    @State private var justLoadedID: UUID?
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
                Panel(title: "Save current state") {
                    saveRow
                    Text("Captures: output routing, matrix sources / gains / mutes / solos, channel names, stereo-link state, and which bus is in view. Output volumes (Monitor, Phones) are not included, so loading a preset never jumps your listening level. Existing presets with the same name are overwritten.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Panel(title: "Saved presets") {
                    if state.presets.isEmpty {
                        Text("No presets yet — save one above.")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                            .padding(.vertical, 6)
                    } else {
                        VStack(spacing: 4) {
                            ForEach(state.presets.sorted(by: { $0.createdAt > $1.createdAt })) { preset in
                                presetRow(preset)
                            }
                        }
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
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Presets").font(.title2).bold().foregroundStyle(Theme.textPrimary)
            Spacer()
            Text("\(state.presets.count) saved")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private var saveRow: some View {
        HStack(spacing: 10) {
            TextField("Preset name", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .onSubmit { savePreset() }

            Button {
                savePreset()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 11))
                    Text("Save")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.muteActive)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1.0)

            Spacer(minLength: 0)
        }
    }

    private func savePreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
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
        let name = renameText.trimmingCharacters(in: .whitespaces)
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
                .foregroundStyle(taken ? Theme.meterHigh : Theme.textSecondary)
        }
    }

    private func presetRow(_ preset: ScarlettPreset) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if renamingID == preset.id {
                presetNameField(preset)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name).font(.subheadline.bold()).foregroundStyle(Theme.textPrimary)
                    Text(Self.dateFormatter.string(from: preset.createdAt))
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                    Text(state.presetDeviceLabel(preset))
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                }
                .help("Click to rename")
            }
            Spacer()
            HStack(spacing: 4) {
                Button {
                    do {
                        try state.userLoadPreset(preset)
                        justLoadedID = preset.id
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            if justLoadedID == preset.id { justLoadedID = nil }
                        }
                    } catch {
                        loadErrorMessage = error.localizedDescription
                    }
                } label: {
                    let loaded = justLoadedID == preset.id
                    HStack(spacing: 4) {
                        if loaded {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                        Text(loaded ? "Loaded" : "Load")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(loaded ? Theme.meterLow.opacity(0.25) : Self.rowButtonFill)
                    .foregroundStyle(loaded ? Theme.meterLow : Theme.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .animation(.easeOut(duration: 0.15), value: loaded)
                }
                .buttonStyle(.plain)

                Button {
                    confirmDelete = preset
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .frame(width: 24, height: 22)
                        .background(Self.rowButtonFill)
                        .foregroundStyle(Theme.meterHigh)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
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
