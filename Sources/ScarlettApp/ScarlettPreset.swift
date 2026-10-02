import Foundation
import ScarlettCore

/// A complete snapshot of every user-controllable bit of state — exactly the
/// stuff a person would want to recall as "my podcast setup" or "tracking
/// drums today".  Persisted in UserDefaults (in-app preset list) and as
/// `.scmx` JSON files via the File menu (Save snapshot / Open snapshot).
/// (Older `.8i6` snapshots still open — import is content-based, not by extension.)
public struct ScarlettPreset: Codable, Identifiable, Hashable {
    public static let currentSchemaVersion = 2

    /// A typed preset name as stored: surrounding spaces trimmed.  Empty
    /// means "no name".
    public static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces)
    }

    public let id: UUID
    public var name: String
    public var createdAt: Date

    /// Added in schema v2. Both are optional so presets written by the older
    /// 8i6/18i8 builds continue to decode and can be migrated safely.
    public var schemaVersion: Int?
    public var productID: UInt16?

    /// Output routing: route raw value → MixBus raw value.
    public var routes: [UInt16: UInt8]

    /// Matrix mixer state (parallel to MixerState fields).
    public var mixerSources: [UInt8]    // 18 × SignalSource raw byte
    public var mixerLevels:  [[Double]] // 18 × profile stereo-pair count
    public var mixerPans:    [[Double]] // 18 × profile stereo-pair count
    public var mixerMutes:   [Bool]     // 18 (per-channel)
    public var mixerSolos:   [Bool]     // 18 (per-channel)
    public var mixerNames:   [String]   // 18

    /// Left-channel indices of linked stereo pairs.
    public var linkedLefts: [Int]

    /// Matrix index of the bus that was active when the snapshot was taken.
    public var selectedBus: UInt8
}

/// The part of the state a preset sets — what "modified since loading"
/// compares.  Leaves out the bus in view, which a preset restores but
/// switching tabs shouldn't count as a change.
struct PresetContent: Codable, Equatable {
    var routes: [UInt16: UInt8]
    var mixerSources: [UInt8]
    var mixerLevels: [[Double]]
    var mixerPans: [[Double]]
    var mixerMutes: [Bool]
    var mixerSolos: [Bool]
    var mixerNames: [String]
    /// Sorted, so equal sets compare equal.
    var linkedLefts: [Int]
}

/// What the user last loaded, and the state right after loading it.  The
/// baseline is taken after the load rather than from the preset, since
/// loading can adjust a preset (duplicate sources dropped, the pinned DAW
/// channels re-claimed).
struct LoadedPreset: Codable, Equatable {
    enum Source: Codable, Equatable {
        /// A saved preset, by id so a rename keeps the link.
        case preset(UUID)
        /// A snapshot file, by file name.
        case file(String)
        case factoryDefault
    }
    var source: Source
    var baseline: PresetContent
}

enum ScarlettPresetError: LocalizedError {
    case notConnected
    case unknownLegacyDevice
    case deviceMismatch(preset: String, connected: String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "No Scarlett is connected."
        case .unknownLegacyDevice:
            return "This legacy preset does not contain enough information to identify its Scarlett model."
        case .deviceMismatch(let preset, let connected):
            return "This preset was created for \(preset), but \(connected) is connected. Presets cannot be applied across models because output numbers have different meanings."
        case .invalid(let reason):
            return "The preset is not valid for the connected Scarlett: \(reason)"
        }
    }
}
