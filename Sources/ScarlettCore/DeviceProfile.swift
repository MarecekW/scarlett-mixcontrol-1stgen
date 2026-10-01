import Foundation

// Per-device configuration for the 1st-gen Scarlett family.  Each profile
// captures the byte mappings + physical layout that the original
// MixControl 1.10.6 binary's per-product IpSigTab/OpSigTab tables encode.
//
// Why a profile rather than per-device enums:
//   The 1st-gen Scarletts share the same control-transfer protocol family
//   (cmd, wValue, wIndex semantics, matrix-cell addressing) but each
//   model assigns *different bytes* to the same conceptual signal.  E.g.
//   Mix M1 is byte 0x14 on the 8i6, 0x18 on the 18i6, 0x1a on the 18i8.
//   Analog 1 is 0x0c on the 8i6, 0x06 on the 18i6, 0x08 on the 18i8.
//
//   Hard-coding one device's bytes into an enum means we can't reuse the
//   protocol layer for a sibling model.  A profile lets the protocol
//   code stay generic and the model-specific bytes live in data.

// MARK: - Profile structures

public struct DeviceProfile: Sendable, Equatable {
    /// Two profiles are equal iff they describe the same device (same PID).
    /// We compare by productID rather than every field because that's the
    /// only thing that practically distinguishes one from another.
    public static func == (a: DeviceProfile, b: DeviceProfile) -> Bool {
        a.productID == b.productID
    }

    /// USB product ID (vendor is always 0x1235 Focusrite).
    public let productID: UInt16
    /// Internal MixControl identifier ("USB14Tracker" etc.) — handy for
    /// debugging and cross-referencing with the original binary.
    public let internalName: String
    /// Marketing name shown to users.
    public let displayName: String
    /// True for everything we've not personally validated on hardware.
    public let isExperimental: Bool

    // ---- Matrix mixer dimensions --------------------------------------
    /// Number of matrix input channels (rows).  18 on every model so far.
    public let matrixInputCount: Int
    /// Number of mix bus outputs (columns).  6 on 8i6 + 18i6, 8 on 18i8.
    public let mixBusCount: Int

    // ---- Sources (signals that can feed matrix channels OR outputs) ---
    /// The full set of signal sources the device knows about, with their
    /// device byte values + display names.  Used by SourceDescriptor pickers
    /// in the matrix UI and by MixBus pickers in the routing UI.
    public let sources: [SourceDescriptor]

    // ---- Physical outputs (routable destinations) ---------------------
    /// Per-device set of physical output destinations.  `wValue` is what
    /// the router accepts in `setRouteSource(wValue:from:)`.
    public let physicalOutputs: [PhysicalOutput]

    // ---- USB capture (DAW input) destinations -------------------------
    /// Number of USB capture channels (the destinations of `setCaptureRoute`).
    /// 8i6 has 6 + 2 loopback; 18i6/18i8 have 14 + 2 loopback.
    public let captureChannelCount: Int
    public let loopbackChannelCount: Int
    /// Profile-specific reset order for USB capture destinations.  This is
    /// intentionally data rather than "first N physical inputs": the 18i8's
    /// established 14-channel layout keeps all eight ADAT inputs.
    public let defaultCaptureSources: [MixBus]

    // ---- Hardware switches --------------------------------------------
    /// Channels (1-indexed in the UI) that have a Line/Inst impedance
    /// toggle.  Empty if the device has no impedance switches.
    public let impedanceChannels: [Int]
    /// Channels (1-indexed) that have a Hi/Lo gain switch.
    public let hiLoChannels: [Int]
    /// Whether the device has a Monitor Mono fold-down switch (currently
    /// disabled in the UI for all models pending an unsolved crash).
    public let hasMonitorMono: Bool

    /// Number of leading physical outputs (by wValue) with a *functional*
    /// post-routing gain/mute stage.  Every output's stage is addressable
    /// (stage = wValue + 1) and reads back what was written, but on digital
    /// outputs (S/PDIF, ADAT) the value is stored without entering the audio
    /// path — confirmed on 18i20 hardware (ADAT fader/mute inaudible) and
    /// matching MixControl's own per-model FFMonitor<N> template sizes:
    /// USB14Tracker(8i6)=4, Saffire6i6=4, USB26Tracker(18i6)=4,
    /// USB24Tracker(18i8)=6, Saffire18i20=10 — i.e. the analog outputs only.
    public let controlledOutputCount: Int

    /// True if this output has a functional gain/mute stage (see
    /// `controlledOutputCount`).
    public func hasGainStage(wValue: UInt16) -> Bool {
        wValue < controlledOutputCount
    }

    /// True when the device has a hardware monitor section the app should
    /// mirror (front-panel volume knob + DIM/MUTE buttons, readable via
    /// `getHardwareMonitorControls`).  Only the 18i20 in the 1st-gen family.
    public var hasHardwareMonitorControls: Bool { productID == 0x800c }
}

public struct SourceDescriptor: Sendable, Hashable, Identifiable {
    /// Wire byte sent to the device.
    public let byte: UInt8
    /// Display name (e.g. "Analog 1", "DAW 3", "Mix M1").
    public let displayName: String
    /// Category — drives grouping in pickers and whether the value can
    /// be the input of a matrix channel ("FromMix" sources feed back the
    /// matrix's own outputs and aren't usually picked).
    public let category: Category

    public var id: UInt8 { byte }

    public enum Category: Sendable, Hashable {
        case off
        case analog
        case digital     // S/PDIF, ADAT
        case daw         // USB host → device
        case mixOutput   // FromMix1..N — matrix output as input to something
    }
}

public struct PhysicalOutput: Sendable, Hashable, Identifiable {
    /// `wValue` for `setRouteSource` on this output.
    public let wValue: UInt16
    /// Friendly name for routing tab labels.
    public let displayName: String
    /// Belongs to which stereo pair.  Used to group "Monitor L+R" rows.
    public let pairLabel: String
    /// True for the left side of its stereo pair.
    public let isLeft: Bool

    public var id: UInt16 { wValue }
}

// MARK: - Profiles

extension DeviceProfile {

    /// All known profiles in this build.  Detection at connect time
    /// matches the device's USB PID against these.
    public static let all: [DeviceProfile] = [.scarlett8i6, .scarlett18i8, .scarlett6i6, .scarlett18i20, .scarlett18i6]

    /// Profiles the app will actively drive (matrix, routing, meters).
    public static let supported: [DeviceProfile] = [.scarlett8i6, .scarlett18i8, .scarlett6i6, .scarlett18i20, .scarlett18i6]

    /// True when this build will open the device and run the full UI flow.
    public var isSupported: Bool { Self.supported.contains { $0.productID == productID } }

    /// Look up a profile by PID.  Returns nil for unknown devices.
    public static func forProductID(_ pid: UInt16) -> DeviceProfile? {
        all.first(where: { $0.productID == pid })
    }

    // ---- Scarlett 8i6 1st gen (USB14Tracker) — VERIFIED ---------------
    public static let scarlett8i6 = DeviceProfile(
        productID: 0x8002,
        internalName: "USB14Tracker",
        displayName: "Scarlett 8i6 (1st gen)",
        isExperimental: false,
        matrixInputCount: 18,
        mixBusCount: 6,
        sources: [
            .init(byte: 0xff, displayName: "Off",       category: .off),
            .init(byte: 0x0c, displayName: "Analog 1",  category: .analog),
            .init(byte: 0x0d, displayName: "Analog 2",  category: .analog),
            .init(byte: 0x0e, displayName: "Analog 3",  category: .analog),
            .init(byte: 0x0f, displayName: "Analog 4",  category: .analog),
            .init(byte: 0x12, displayName: "S/PDIF 1",  category: .digital),
            .init(byte: 0x13, displayName: "S/PDIF 2",  category: .digital),
            .init(byte: 0x00, displayName: "DAW 1",     category: .daw),
            .init(byte: 0x01, displayName: "DAW 2",     category: .daw),
            .init(byte: 0x02, displayName: "DAW 3",     category: .daw),
            .init(byte: 0x03, displayName: "DAW 4",     category: .daw),
            .init(byte: 0x04, displayName: "DAW 5",     category: .daw),
            .init(byte: 0x05, displayName: "DAW 6",     category: .daw),
            .init(byte: 0x14, displayName: "Mix M1",    category: .mixOutput),
            .init(byte: 0x15, displayName: "Mix M2",    category: .mixOutput),
            .init(byte: 0x16, displayName: "Mix M3",    category: .mixOutput),
            .init(byte: 0x17, displayName: "Mix M4",    category: .mixOutput),
            .init(byte: 0x18, displayName: "Mix M5",    category: .mixOutput),
            .init(byte: 0x19, displayName: "Mix M6",    category: .mixOutput),
        ],
        physicalOutputs: [
            .init(wValue: 0, displayName: "Monitor L",   pairLabel: "Monitor", isLeft: true),
            .init(wValue: 1, displayName: "Monitor R",   pairLabel: "Monitor", isLeft: false),
            .init(wValue: 2, displayName: "Phones L",    pairLabel: "Phones",  isLeft: true),
            .init(wValue: 3, displayName: "Phones R",    pairLabel: "Phones",  isLeft: false),
            .init(wValue: 4, displayName: "S/PDIF L",    pairLabel: "S/PDIF",  isLeft: true),
            .init(wValue: 5, displayName: "S/PDIF R",    pairLabel: "S/PDIF",  isLeft: false),
        ],
        captureChannelCount: 6,
        loopbackChannelCount: 2,
        defaultCaptureSources: [.analog1, .analog2, .analog3, .analog4, .spdif1, .spdif2],
        impedanceChannels: [1, 2],
        hiLoChannels: [3, 4],
        hasMonitorMono: false,   // hidden until the disconnect is solved
        controlledOutputCount: 4
    )

    // ---- Scarlett 18i6 1st gen (USB26Tracker) — EXPERIMENTAL ----------
    //
    // 8 analog inputs, 2 S/PDIF, 8 ADAT, 6 DAW.  Matrix is 18 × 6.
    // Routing destinations: Monitor + Phones + S/PDIF (6 outputs).
    public static let scarlett18i6 = DeviceProfile(
        productID: 0x8004,
        internalName: "USB26Tracker",
        displayName: "Scarlett 18i6 (1st gen)",
        isExperimental: true,
        matrixInputCount: 18,
        mixBusCount: 6,
        sources: [
            .init(byte: 0xff, displayName: "Off",       category: .off),
            .init(byte: 0x06, displayName: "Analog 1",  category: .analog),
            .init(byte: 0x07, displayName: "Analog 2",  category: .analog),
            .init(byte: 0x08, displayName: "Analog 3",  category: .analog),
            .init(byte: 0x09, displayName: "Analog 4",  category: .analog),
            .init(byte: 0x0a, displayName: "Analog 5",  category: .analog),
            .init(byte: 0x0b, displayName: "Analog 6",  category: .analog),
            .init(byte: 0x0c, displayName: "Analog 7",  category: .analog),
            .init(byte: 0x0d, displayName: "Analog 8",  category: .analog),
            .init(byte: 0x0e, displayName: "S/PDIF 1",  category: .digital),
            .init(byte: 0x0f, displayName: "S/PDIF 2",  category: .digital),
            .init(byte: 0x10, displayName: "ADAT 1",    category: .digital),
            .init(byte: 0x11, displayName: "ADAT 2",    category: .digital),
            .init(byte: 0x12, displayName: "ADAT 3",    category: .digital),
            .init(byte: 0x13, displayName: "ADAT 4",    category: .digital),
            .init(byte: 0x14, displayName: "ADAT 5",    category: .digital),
            .init(byte: 0x15, displayName: "ADAT 6",    category: .digital),
            .init(byte: 0x16, displayName: "ADAT 7",    category: .digital),
            .init(byte: 0x17, displayName: "ADAT 8",    category: .digital),
            .init(byte: 0x00, displayName: "DAW 1",     category: .daw),
            .init(byte: 0x01, displayName: "DAW 2",     category: .daw),
            .init(byte: 0x02, displayName: "DAW 3",     category: .daw),
            .init(byte: 0x03, displayName: "DAW 4",     category: .daw),
            .init(byte: 0x04, displayName: "DAW 5",     category: .daw),
            .init(byte: 0x05, displayName: "DAW 6",     category: .daw),
            .init(byte: 0x18, displayName: "Mix M1",    category: .mixOutput),
            .init(byte: 0x19, displayName: "Mix M2",    category: .mixOutput),
            .init(byte: 0x1a, displayName: "Mix M3",    category: .mixOutput),
            .init(byte: 0x1b, displayName: "Mix M4",    category: .mixOutput),
            .init(byte: 0x1c, displayName: "Mix M5",    category: .mixOutput),
            .init(byte: 0x1d, displayName: "Mix M6",    category: .mixOutput),
        ],
        physicalOutputs: [
            .init(wValue: 0, displayName: "Monitor L",  pairLabel: "Monitor", isLeft: true),
            .init(wValue: 1, displayName: "Monitor R",  pairLabel: "Monitor", isLeft: false),
            .init(wValue: 2, displayName: "Phones L",   pairLabel: "Phones",  isLeft: true),
            .init(wValue: 3, displayName: "Phones R",   pairLabel: "Phones",  isLeft: false),
            .init(wValue: 4, displayName: "S/PDIF L",   pairLabel: "S/PDIF",  isLeft: true),
            .init(wValue: 5, displayName: "S/PDIF R",   pairLabel: "S/PDIF",  isLeft: false),
        ],
        captureChannelCount: 18,    // 18 ToHost slots in USB26Tracker_OpSigTab
        loopbackChannelCount: 0,    // no Loop. entries in OpSigTab kind=3 list
        defaultCaptureSources: [
            .analog1, .analog2, .analog3, .analog4, .analog5, .analog6, .analog7, .analog8,
            .spdif1, .spdif2,
            .adat1, .adat2, .adat3, .adat4, .adat5, .adat6, .adat7, .adat8,
        ],
        impedanceChannels: [1, 2],  // Inputs 1+2 are combo jacks (mic preamp)
        hiLoChannels: [],           // 18i6 has separate Hi-Z buttons on mics, not Hi/Lo
        hasMonitorMono: false,
        controlledOutputCount: 4
    )

    // ---- Scarlett 18i8 1st gen (USB24Tracker) — SUPPORTED ------------
    //
    // 8 analog + 2 S/PDIF + 8 ADAT + 8 DAW.  Matrix is 18 × 8.
    // Wire bytes verified against Linux `s18i8_info` in mixer_scarlett.c.
    // 8 routable physical outputs (Monitor + Phones + Line 5/6 + S/PDIF).
    public static let scarlett18i8 = DeviceProfile(
        productID: 0x8014,
        internalName: "USB24Tracker",
        displayName: "Scarlett 18i8 (1st gen)",
        isExperimental: false,
        matrixInputCount: 18,
        mixBusCount: 8,
        sources: [
            .init(byte: 0xff, displayName: "Off",       category: .off),
            .init(byte: 0x08, displayName: "Analog 1",  category: .analog),
            .init(byte: 0x09, displayName: "Analog 2",  category: .analog),
            .init(byte: 0x0a, displayName: "Analog 3",  category: .analog),
            .init(byte: 0x0b, displayName: "Analog 4",  category: .analog),
            .init(byte: 0x0c, displayName: "Analog 5",  category: .analog),
            .init(byte: 0x0d, displayName: "Analog 6",  category: .analog),
            .init(byte: 0x0e, displayName: "Analog 7",  category: .analog),
            .init(byte: 0x0f, displayName: "Analog 8",  category: .analog),
            .init(byte: 0x10, displayName: "S/PDIF 1",  category: .digital),
            .init(byte: 0x11, displayName: "S/PDIF 2",  category: .digital),
            .init(byte: 0x12, displayName: "ADAT 1",    category: .digital),
            .init(byte: 0x13, displayName: "ADAT 2",    category: .digital),
            .init(byte: 0x14, displayName: "ADAT 3",    category: .digital),
            .init(byte: 0x15, displayName: "ADAT 4",    category: .digital),
            .init(byte: 0x16, displayName: "ADAT 5",    category: .digital),
            .init(byte: 0x17, displayName: "ADAT 6",    category: .digital),
            .init(byte: 0x18, displayName: "ADAT 7",    category: .digital),
            .init(byte: 0x19, displayName: "ADAT 8",    category: .digital),
            .init(byte: 0x00, displayName: "DAW 1",     category: .daw),
            .init(byte: 0x01, displayName: "DAW 2",     category: .daw),
            .init(byte: 0x02, displayName: "DAW 3",     category: .daw),
            .init(byte: 0x03, displayName: "DAW 4",     category: .daw),
            .init(byte: 0x04, displayName: "DAW 5",     category: .daw),
            .init(byte: 0x05, displayName: "DAW 6",     category: .daw),
            .init(byte: 0x06, displayName: "DAW 7",     category: .daw),
            .init(byte: 0x07, displayName: "DAW 8",     category: .daw),
            .init(byte: 0x1a, displayName: "Mix M1",    category: .mixOutput),
            .init(byte: 0x1b, displayName: "Mix M2",    category: .mixOutput),
            .init(byte: 0x1c, displayName: "Mix M3",    category: .mixOutput),
            .init(byte: 0x1d, displayName: "Mix M4",    category: .mixOutput),
            .init(byte: 0x1e, displayName: "Mix M5",    category: .mixOutput),
            .init(byte: 0x1f, displayName: "Mix M6",    category: .mixOutput),
            .init(byte: 0x20, displayName: "Mix M7",    category: .mixOutput),
            .init(byte: 0x21, displayName: "Mix M8",    category: .mixOutput),
        ],
        physicalOutputs: [
            .init(wValue: 0, displayName: "Monitor L",   pairLabel: "Monitor",  isLeft: true),
            .init(wValue: 1, displayName: "Monitor R",   pairLabel: "Monitor",  isLeft: false),
            .init(wValue: 2, displayName: "Phones L",    pairLabel: "Phones",   isLeft: true),
            .init(wValue: 3, displayName: "Phones R",    pairLabel: "Phones",   isLeft: false),
            .init(wValue: 4, displayName: "Line Out 5",  pairLabel: "Line 5+6", isLeft: true),
            .init(wValue: 5, displayName: "Line Out 6",  pairLabel: "Line 5+6", isLeft: false),
            .init(wValue: 6, displayName: "S/PDIF L",    pairLabel: "S/PDIF",   isLeft: true),
            .init(wValue: 7, displayName: "S/PDIF R",    pairLabel: "S/PDIF",   isLeft: false),
        ],
        captureChannelCount: 14,
        loopbackChannelCount: 2,
        defaultCaptureSources: [
            .analog1, .analog2, .analog3, .analog4,
            .spdif1, .spdif2,
            .adat1, .adat2, .adat3, .adat4, .adat5, .adat6, .adat7, .adat8,
        ],
        impedanceChannels: [1, 2],
        hiLoChannels: [],
        hasMonitorMono: false,
        controlledOutputCount: 6
    )

    // ---- Scarlett 6i6 1st gen (Saffire6i6 table) — EXPERIMENTAL -------
    //
    // 4 analog (2 combo mic/line + 2 line) + 2 S/PDIF = 6 inputs; 6 DAW
    // playback.  Matrix is 18 × 8 (MixControl exposes 4 stereo mixes).
    // 6 routable outputs: Monitor + Phones + S/PDIF.
    //
    // Bytes extracted from MixControl 1.10.6's `Saffire6i6_IpSigTab` /
    // `_OpSigTab`.  The class is named "Saffire6i6" for legacy reasons but
    // its `getDeviceTitle()` returns "Scarlett 6i6"; PID 0x8012 confirmed
    // both from the binary's own device dispatch (`cmpl $0x8012`) and the
    // DeviceHunt USB database.  Analog 1-4 = 0x0c..0x0f, S/PDIF = 0x10/0x11,
    // DAW = 0x00..0x0b, Mix M1..M8 = 0x12..0x19.
    public static let scarlett6i6 = DeviceProfile(
        productID: 0x8012,
        internalName: "Saffire6i6",
        displayName: "Scarlett 6i6 (1st gen)",
        isExperimental: true,
        matrixInputCount: 18,
        mixBusCount: 8,
        sources: [
            .init(byte: 0xff, displayName: "Off",       category: .off),
            .init(byte: 0x0c, displayName: "Analog 1",  category: .analog),
            .init(byte: 0x0d, displayName: "Analog 2",  category: .analog),
            .init(byte: 0x0e, displayName: "Analog 3",  category: .analog),
            .init(byte: 0x0f, displayName: "Analog 4",  category: .analog),
            .init(byte: 0x10, displayName: "S/PDIF 1",  category: .digital),
            .init(byte: 0x11, displayName: "S/PDIF 2",  category: .digital),
            .init(byte: 0x00, displayName: "DAW 1",     category: .daw),
            .init(byte: 0x01, displayName: "DAW 2",     category: .daw),
            .init(byte: 0x02, displayName: "DAW 3",     category: .daw),
            .init(byte: 0x03, displayName: "DAW 4",     category: .daw),
            .init(byte: 0x04, displayName: "DAW 5",     category: .daw),
            .init(byte: 0x05, displayName: "DAW 6",     category: .daw),
            .init(byte: 0x12, displayName: "Mix M1",    category: .mixOutput),
            .init(byte: 0x13, displayName: "Mix M2",    category: .mixOutput),
            .init(byte: 0x14, displayName: "Mix M3",    category: .mixOutput),
            .init(byte: 0x15, displayName: "Mix M4",    category: .mixOutput),
            .init(byte: 0x16, displayName: "Mix M5",    category: .mixOutput),
            .init(byte: 0x17, displayName: "Mix M6",    category: .mixOutput),
            .init(byte: 0x18, displayName: "Mix M7",    category: .mixOutput),
            .init(byte: 0x19, displayName: "Mix M8",    category: .mixOutput),
        ],
        physicalOutputs: [
            .init(wValue: 0, displayName: "Monitor L",   pairLabel: "Monitor", isLeft: true),
            .init(wValue: 1, displayName: "Monitor R",   pairLabel: "Monitor", isLeft: false),
            .init(wValue: 2, displayName: "Phones L",    pairLabel: "Phones",  isLeft: true),
            .init(wValue: 3, displayName: "Phones R",    pairLabel: "Phones",  isLeft: false),
            .init(wValue: 4, displayName: "S/PDIF L",    pairLabel: "S/PDIF",  isLeft: true),
            .init(wValue: 5, displayName: "S/PDIF R",    pairLabel: "S/PDIF",  isLeft: false),
        ],
        captureChannelCount: 6,
        loopbackChannelCount: 0,
        defaultCaptureSources: [.analog1, .analog2, .analog3, .analog4, .spdif1, .spdif2],
        impedanceChannels: [1, 2],  // 2 combo mic/line inputs
        hiLoChannels: [],
        hasMonitorMono: false,
        controlledOutputCount: 4
    )

    // ---- Scarlett 18i20 1st gen (Saffire18i20 table) — VERIFIED --------
    //
    // 8 analog + 2 S/PDIF + 8 ADAT = 18 inputs; 20 DAW playback.  Matrix is
    // 18 × 8.  20 physical outputs: Monitor + 8 line + S/PDIF + 8 ADAT.
    //
    // Bytes extracted from MixControl 1.10.6's `Saffire18i20_IpSigTab` /
    // `_OpSigTab` (getDeviceTitle() → "Scarlett 18i20").  PID 0x800c
    // confirmed from the binary's device dispatch and the Linux gen-1 driver.
    // Note: this is the *1st-gen* 18i20 — the 2nd-gen unit is a different
    // protocol entirely and is NOT this device.
    // Analog 1-8 = 0x14..0x1b, S/PDIF = 0x1c/0x1d, ADAT 1-8 = 0x1e..0x25,
    // DAW 1-20 = 0x00..0x13, Mix M1..M8 = 0x26..0x2d.
    //
    // Unlike the 8i6/18i6/18i8/6i6, this device has no dedicated "Phones"
    // wValue — the front-panel headphone jacks are hardwired analog taps of
    // two of the rear line outputs. Per Focusrite's own support article
    // ("How do the headphone outputs work on the Scarlett 18i20?", which
    // states this applies to 1st/2nd/3rd gen alike): Headphone 1 L/R taps
    // Line Out 7/8, Headphone 2 L/R taps Line Out 9/10. Whatever is routed
    // to those wValues plays on both the rear jack and the matching front
    // headphone jack, through the same per-output gain stage.
    public static let scarlett18i20 = DeviceProfile(
        productID: 0x800c,
        internalName: "Saffire18i20",
        displayName: "Scarlett 18i20 (1st gen)",
        isExperimental: false,   // confirmed on hardware: routing, matrix,
                                 // meters, output stages, hw monitor section
        matrixInputCount: 18,
        mixBusCount: 8,
        sources: [
            .init(byte: 0xff, displayName: "Off",       category: .off),
            .init(byte: 0x14, displayName: "Analog 1",  category: .analog),
            .init(byte: 0x15, displayName: "Analog 2",  category: .analog),
            .init(byte: 0x16, displayName: "Analog 3",  category: .analog),
            .init(byte: 0x17, displayName: "Analog 4",  category: .analog),
            .init(byte: 0x18, displayName: "Analog 5",  category: .analog),
            .init(byte: 0x19, displayName: "Analog 6",  category: .analog),
            .init(byte: 0x1a, displayName: "Analog 7",  category: .analog),
            .init(byte: 0x1b, displayName: "Analog 8",  category: .analog),
            .init(byte: 0x1c, displayName: "S/PDIF 1",  category: .digital),
            .init(byte: 0x1d, displayName: "S/PDIF 2",  category: .digital),
            .init(byte: 0x1e, displayName: "ADAT 1",    category: .digital),
            .init(byte: 0x1f, displayName: "ADAT 2",    category: .digital),
            .init(byte: 0x20, displayName: "ADAT 3",    category: .digital),
            .init(byte: 0x21, displayName: "ADAT 4",    category: .digital),
            .init(byte: 0x22, displayName: "ADAT 5",    category: .digital),
            .init(byte: 0x23, displayName: "ADAT 6",    category: .digital),
            .init(byte: 0x24, displayName: "ADAT 7",    category: .digital),
            .init(byte: 0x25, displayName: "ADAT 8",    category: .digital),
            .init(byte: 0x00, displayName: "DAW 1",     category: .daw),
            .init(byte: 0x01, displayName: "DAW 2",     category: .daw),
            .init(byte: 0x02, displayName: "DAW 3",     category: .daw),
            .init(byte: 0x03, displayName: "DAW 4",     category: .daw),
            .init(byte: 0x04, displayName: "DAW 5",     category: .daw),
            .init(byte: 0x05, displayName: "DAW 6",     category: .daw),
            .init(byte: 0x06, displayName: "DAW 7",     category: .daw),
            .init(byte: 0x07, displayName: "DAW 8",     category: .daw),
            .init(byte: 0x08, displayName: "DAW 9",     category: .daw),
            .init(byte: 0x09, displayName: "DAW 10",    category: .daw),
            .init(byte: 0x0a, displayName: "DAW 11",    category: .daw),
            .init(byte: 0x0b, displayName: "DAW 12",    category: .daw),
            .init(byte: 0x0c, displayName: "DAW 13",    category: .daw),
            .init(byte: 0x0d, displayName: "DAW 14",    category: .daw),
            .init(byte: 0x0e, displayName: "DAW 15",    category: .daw),
            .init(byte: 0x0f, displayName: "DAW 16",    category: .daw),
            .init(byte: 0x10, displayName: "DAW 17",    category: .daw),
            .init(byte: 0x11, displayName: "DAW 18",    category: .daw),
            .init(byte: 0x12, displayName: "DAW 19",    category: .daw),
            .init(byte: 0x13, displayName: "DAW 20",    category: .daw),
            .init(byte: 0x26, displayName: "Mix M1",    category: .mixOutput),
            .init(byte: 0x27, displayName: "Mix M2",    category: .mixOutput),
            .init(byte: 0x28, displayName: "Mix M3",    category: .mixOutput),
            .init(byte: 0x29, displayName: "Mix M4",    category: .mixOutput),
            .init(byte: 0x2a, displayName: "Mix M5",    category: .mixOutput),
            .init(byte: 0x2b, displayName: "Mix M6",    category: .mixOutput),
            .init(byte: 0x2c, displayName: "Mix M7",    category: .mixOutput),
            .init(byte: 0x2d, displayName: "Mix M8",    category: .mixOutput),
        ],
        physicalOutputs: [
            .init(wValue: 0x00, displayName: "Monitor L",  pairLabel: "Monitor",   isLeft: true),
            .init(wValue: 0x01, displayName: "Monitor R",  pairLabel: "Monitor",   isLeft: false),
            .init(wValue: 0x02, displayName: "Line Out 3", pairLabel: "Line 3+4",  isLeft: true),
            .init(wValue: 0x03, displayName: "Line Out 4", pairLabel: "Line 3+4",  isLeft: false),
            .init(wValue: 0x04, displayName: "Line Out 5", pairLabel: "Line 5+6",  isLeft: true),
            .init(wValue: 0x05, displayName: "Line Out 6", pairLabel: "Line 5+6",  isLeft: false),
            // Line 7/8 and 9/10 are mirrored on the front-panel headphone
            // jacks 1 and 2 — per MixControl's own monitor presets
            // ("Mid+Phones 1" = outs 7+8, "Mini+Phones 2" = outs 9+10).
            .init(wValue: 0x06, displayName: "Line Out 7", pairLabel: "Phones 1",  isLeft: true),
            .init(wValue: 0x07, displayName: "Line Out 8", pairLabel: "Phones 1",  isLeft: false),
            .init(wValue: 0x08, displayName: "Line Out 9", pairLabel: "Phones 2",  isLeft: true),
            .init(wValue: 0x09, displayName: "Line Out 10",pairLabel: "Phones 2",  isLeft: false),
            .init(wValue: 0x0a, displayName: "S/PDIF L",   pairLabel: "S/PDIF",    isLeft: true),
            .init(wValue: 0x0b, displayName: "S/PDIF R",   pairLabel: "S/PDIF",    isLeft: false),
            .init(wValue: 0x0c, displayName: "ADAT 1",     pairLabel: "ADAT 1+2",  isLeft: true),
            .init(wValue: 0x0d, displayName: "ADAT 2",     pairLabel: "ADAT 1+2",  isLeft: false),
            .init(wValue: 0x0e, displayName: "ADAT 3",     pairLabel: "ADAT 3+4",  isLeft: true),
            .init(wValue: 0x0f, displayName: "ADAT 4",     pairLabel: "ADAT 3+4",  isLeft: false),
            .init(wValue: 0x10, displayName: "ADAT 5",     pairLabel: "ADAT 5+6",  isLeft: true),
            .init(wValue: 0x11, displayName: "ADAT 6",     pairLabel: "ADAT 5+6",  isLeft: false),
            .init(wValue: 0x12, displayName: "ADAT 7",     pairLabel: "ADAT 7+8",  isLeft: true),
            .init(wValue: 0x13, displayName: "ADAT 8",     pairLabel: "ADAT 7+8",  isLeft: false),
        ],
        captureChannelCount: 18,
        loopbackChannelCount: 0,
        defaultCaptureSources: [
            .analog1, .analog2, .analog3, .analog4, .analog5, .analog6, .analog7, .analog8,
            .spdif1, .spdif2,
            .adat1, .adat2, .adat3, .adat4, .adat5, .adat6, .adat7, .adat8,
        ],
        impedanceChannels: [],   // 8 mic pres; inst/pad switches unverified
        hiLoChannels: [],
        hasMonitorMono: false,
        controlledOutputCount: 10
    )
}

// MARK: - Convenience accessors

extension DeviceProfile {
    /// Look up a source by its wire byte (or fall back to Off).
    public func source(forByte byte: UInt8) -> SourceDescriptor {
        sources.first(where: { $0.byte == byte })
            ?? SourceDescriptor(byte: 0xff, displayName: "Off (0x\(String(byte, radix: 16)))", category: .off)
    }

    /// Sources that are valid inputs to a matrix-mixer channel — everything
    /// except other matrix outputs (which would create a feedback loop unless
    /// the user explicitly wants it).
    public var matrixChannelSources: [SourceDescriptor] {
        sources.filter { $0.category != .mixOutput }
    }

    /// All Mix M1..Mn entries in source order.  Used to populate router pickers.
    public var mixBusSources: [SourceDescriptor] {
        sources.filter { $0.category == .mixOutput }
    }

    /// Stereo bus pairs in the matrix (M1+M2, M3+M4, …).
    public var stereoPairCount: Int { mixBusCount / 2 }

    /// DAW playback channels surfaced in peak meters.
    public var dawMeterCount: Int {
        sources.filter { $0.category == .daw }.count
    }

    /// Sources valid in output-routing and USB-capture pickers.
    public var routerSources: [SourceDescriptor] {
        sources.filter { $0.category != .mixOutput || mixBusSources.contains($0) }
            .filter { $0.category != .off }
            .sorted { $0.byte < $1.byte }
            .reduce(into: [SourceDescriptor]()) { acc, s in
                if !acc.contains(where: { $0.byte == s.byte }) { acc.append(s) }
            }
    }

    /// Router pickers always include Off + every routable source + mix buses.
    public var routerPickerSources: [SourceDescriptor] {
        let off = sources.first(where: { $0.category == .off })
            ?? SourceDescriptor(byte: 0xff, displayName: "Off", category: .off)
        return [off] + sources.filter { $0.category != .off }
    }

    /// Index into `PeakReading.inputs` for a hardware input source byte,
    /// or nil when the device does not expose a meter for that source.
    public func inputMeterIndex(forByte byte: UInt8) -> Int? {
        switch productID {
        case 0x8002: // 8i6 — verified layout
            switch byte {
            case 0x0c: return 0; case 0x0d: return 1
            case 0x0e: return 2; case 0x0f: return 3
            case 0x12: return 8; case 0x13: return 9
            default: return nil
            }
        case 0x8014: // 18i8 — 8 analog @ 0x08–0x0f, S/PDIF @ 0x10–0x11, ADAT @ 0x12–0x19
            switch byte {
            case 0x08...0x0f: return Int(byte - 0x08)
            case 0x10: return 8; case 0x11: return 9
            case 0x12...0x19: return Int(byte - 0x12 + 10)
            default: return nil
            }
        case 0x8004: // 18i6 — 8 analog @ 0–7, S/PDIF @ 8–9, ADAT @ 10–17
            switch byte {
            case 0x06...0x0d: return Int(byte - 0x06)
            case 0x0e: return 8; case 0x0f: return 9
            case 0x10...0x17: return Int(byte - 0x10 + 10)
            default: return nil
            }
        case 0x8012: // 6i6 — 4 analog @ 0x0c–0x0f, S/PDIF @ 0x10–0x11.
            // Meter slots assumed to mirror the 8i6 (its closest analog+S/PDIF
            // sibling); unverified on hardware — a tester should confirm.
            switch byte {
            case 0x0c: return 0; case 0x0d: return 1
            case 0x0e: return 2; case 0x0f: return 3
            case 0x10: return 8; case 0x11: return 9
            default: return nil
            }
        case 0x800c: // 18i20 — 8 analog @ 0x14–0x1b, S/PDIF @ 0x1c–0x1d, ADAT @ 0x1e–0x25.
            // Meter slots assumed to follow the 18i8/18i6 shape; unverified.
            switch byte {
            case 0x14...0x1b: return Int(byte - 0x14)
            case 0x1c: return 8; case 0x1d: return 9
            case 0x1e...0x25: return Int(byte - 0x1e + 10)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Index into `PeakReading.daw` for a DAW source byte.  Matches on the
    /// device's own DAW source list (bytes go up to 0x13 on the 18i20's 20 DAW
    /// channels), so there's no fixed 12-channel cap; a non-DAW byte returns nil
    /// and falls through to the input/mix meter lookups.
    public func dawMeterIndex(forByte byte: UInt8) -> Int? {
        let daw = sources.filter { $0.category == .daw }.sorted { $0.byte < $1.byte }
        return daw.firstIndex(where: { $0.byte == byte })
    }

    /// Index into `PeakReading.mixer` for a mix-output source byte.
    public func mixMeterIndex(forByte byte: UInt8) -> Int? {
        let mixes = mixBusSources
        return mixes.firstIndex(where: { $0.byte == byte })
    }

    /// Translate a canonical app `MixBus` case to this device's wire byte.
    public func wireByte(for bus: MixBus) -> UInt8 {
        if bus == .off { return 0xff }
        let name = bus.displayName
        if let match = sources.first(where: { $0.displayName == name }) {
            return match.byte
        }
        return bus.rawValue
    }

    /// Resolve only values explicitly advertised by this profile.  Device
    /// writes use this stricter form so canonical sentinel IDs (for example
    /// DAW 13 = 0xc0) can never leak onto an incompatible interface.
    public func supportedWireByte(for bus: MixBus) -> UInt8? {
        if bus == .off { return 0xff }
        return sources.first(where: { $0.displayName == bus.displayName })?.byte
    }

    /// Decode a device wire byte into the canonical `MixBus` the UI uses.
    public func mixBus(fromWireByte byte: UInt8) -> MixBus {
        if byte == 0xff { return .off }
        if let desc = sources.first(where: { $0.byte == byte }) {
            return MixBus.fromDisplayName(desc.displayName) ?? MixBus(rawValue: byte) ?? .off
        }
        return MixBus(rawValue: byte) ?? .off
    }

    /// Translate a canonical app `SignalSource` to this device's wire byte.
    public func wireByte(for signal: SignalSource) -> UInt8 {
        if signal == .off { return 0xff }
        let name = signal.displayName
        if let match = sources.first(where: { $0.displayName == name }) {
            return match.byte
        }
        return signal.rawValue
    }

    /// SignalSource counterpart to `supportedWireByte(for: MixBus)`.
    public func supportedWireByte(for signal: SignalSource) -> UInt8? {
        if signal == .off { return 0xff }
        return sources.first(where: { $0.displayName == signal.displayName })?.byte
    }

    /// Decode a device wire byte into the canonical `SignalSource`.
    public func signalSource(fromWireByte byte: UInt8) -> SignalSource {
        if byte == 0xff { return .off }
        if let desc = sources.first(where: { $0.byte == byte }) {
            return SignalSource.fromDisplayName(desc.displayName) ?? SignalSource(rawValue: byte) ?? .off
        }
        return SignalSource(rawValue: byte) ?? .off
    }

    /// Mix buses M1..Mn as canonical enum values (length == mixBusCount).
    public var matrixOutputBuses: [MixBus] {
        (0..<mixBusCount).map { MixBus.fromMatrixIndex($0) }
    }
}
