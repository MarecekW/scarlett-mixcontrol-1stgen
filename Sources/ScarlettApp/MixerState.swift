import Foundation
import Observation
import AppKit
import CoreAudio
import IOKit
import ScarlettCore

/// High-level connection state of the Scarlett device.  Tracked separately from
/// the device handle so the UI can render meaningful "waiting" / "disconnected"
/// states distinct from "open but erroring on a single transfer".
public enum ConnectionState: Equatable {
    case waiting                          // App is up, nothing plugged in yet
    case connected                        // Device handle opened and last poll succeeded
    case disconnected(String)             // Was connected, lost — reason for display
    case unsupported(DeviceProfile)       // Found a Focusrite this build can't drive yet
}

// View model holding the live device handle, the latest peak meter reading,
// and the user's current slider/toggle positions. Writes to the device are
// only sent when the user changes a value — the model never tries to
// "sync" itself to the hardware on launch (we have no GET for most state).

@MainActor
@Observable
final class MixerState {
    // MARK: - Connection
    var device: ScarlettDevice?
    var connection: ConnectionState = .waiting
    var firmware: String = "—"
    var serial: String = "—"

    /// Active device profile — falls back to 8i6 layout before connect.
    var profile: DeviceProfile { device?.profile ?? .scarlett8i6 }

    /// Mix buses M1..Mn for the connected device.
    var matrixBuses: [MixBus] { profile.matrixOutputBuses }

    /// Stereo pairs in the matrix (3 on the 6-bus 8i6/18i6, 4 on the 8-bus 18i8/18i20/6i6).
    var stereoPairCount: Int { profile.stereoPairCount }

    /// Sources shown in matrix-channel pickers for the connected device.
    /// On devices with the pinned DAW return, DAW 1/2 are left out: picking
    /// one on a regular strip would steal it from the pinned channels, which
    /// stay Off afterwards and silently drop playback from every mix.
    var matrixSourceOptions: [SignalSource] {
        var seen = Set<UInt8>()
        let reserved: Set<SignalSource> = hasPinnedDawReturn ? [.daw1, .daw2] : []
        return profile.matrixChannelSources.compactMap { desc in
            let src = profile.signalSource(fromWireByte: desc.byte)
            guard !reserved.contains(src), seen.insert(src.rawValue).inserted else { return nil }
            return src
        }
    }

    /// Sources shown in routing / capture pickers (unique MixBus ids for SwiftUI ForEach).
    var routerPickerOptions: [MixBus] {
        var seen = Set<UInt8>()
        return profile.routerPickerSources.compactMap { desc in
            let bus = profile.mixBus(fromWireByte: desc.byte)
            guard seen.insert(bus.rawValue).inserted else { return nil }
            return bus
        }
    }

    /// Grouped physical outputs for the routing tab (pair label → outputs).
    var physicalOutputGroups: [(label: String, outputs: [PhysicalOutput])] {
        var order: [String] = []
        var groups: [String: [PhysicalOutput]] = [:]
        for out in profile.physicalOutputs {
            if groups[out.pairLabel] == nil { order.append(out.pairLabel) }
            groups[out.pairLabel, default: []].append(out)
        }
        return order.compactMap { label in
            guard let outputs = groups[label], !outputs.isEmpty else { return nil }
            return (label, outputs)
        }
    }

    /// Back-compat: existing call sites read a single error string. Surfaces
    /// the most recent disconnect reason, otherwise nil.
    var connectionError: String? {
        if case .disconnected(let reason) = connection { return reason }
        return nil
    }

    /// Serial queue used to push USB writes off the main actor.  USB control
    /// transfers are fast (microseconds) but synchronous, and SwiftUI sliders
    /// fire ~60 updates/sec while dragging — running those on main causes
    /// visible jank.  All writes go through `writeAsync`.
    @ObservationIgnored
    private let usbQueue = DispatchQueue(label: "scarlett.usb-writes", qos: .userInitiated)

    nonisolated private func writeAsync(_ work: @escaping @Sendable () -> Void) {
        usbQueue.async(execute: work)
    }

    // MARK: - Meters
    var peaks: PeakReading = .empty
    /// Decayed peak-hold values per source. Updated on every poll: each value
    /// either keeps the new live reading (if higher) or decays the previous
    /// hold by `peakDecayDbPerSecond * elapsed`.
    var peaksHeld: PeakReading = .empty
    /// "All-time" peak per source — never decays automatically. Useful for
    /// gain staging: glance at the strip to see how loud each channel has
    /// peaked since you last cleared.  Reset via `clearMaxPeaks()`.
    var peaksMax: PeakReading = .empty
    var metersStale: Bool = false   // true if last poll failed
    @ObservationIgnored private let peakDecayDbPerSecond: Double = 6
    @ObservationIgnored private var syncPollAccumulator: TimeInterval = 0
    @ObservationIgnored private var restoringProfileState = false

    // MARK: - User-controlled values (defaults to "no change")
    //
    // Attenuation sliders: -60...0 dB range, default 0 = no attenuation.
    // We start sliders at 0 dB but DO NOT push that value to the device on
    // launch (the user might be running at -20 dB right now and we'd boost
    // them). First user change sends the value.
    //
    // Output gain stages are per-physical-output (stage = wValue + 1 on the
    // device).  One fader per stereo pair, keyed by the pair's LEFT output
    // wValue; per-side mutes keyed by each output's own wValue.
    var pairAttens: [UInt16: Double] = [:]
    var outputMutes: [UInt16: Bool] = [:]
    var masterMuted: Bool    = false

    /// Which output pairs (by `PhysicalOutput.pairLabel`) are shown as pinned
    /// strips in the mixer.  Persisted per device.  Any pair — including
    /// Monitor — can be hidden; the Outputs menu brings them back.
    var visiblePairLabels: Set<String> = []

    // Input switches — defaults are conservative (line / lo). Not pushed on launch.
    var impedance1: Impedance = .line
    var impedance2: Impedance = .line
    var hi3: Bool = false   // false = lo, true = hi
    var hi4: Bool = false

    /// Convenience for the (very common) `is the device usable right now` check.
    var isConnected: Bool { connection == .connected }

    /// Physical output routing keyed by `PhysicalOutput.wValue`.
    var routes: [UInt16: MixBus] = [:]

    // Device config — default values shown, not pushed on launch.
    var clock: ClockSource = .internalClock
    var sampleRate: UInt32 = 48000
    var syncLocked: Bool = false

    // Dim: -20 dB attenuation overlay on monitor outputs. Stores the
    // pre-dim attenuation so we can restore it.
    var dimEnabled: Bool = false
    @ObservationIgnored private var preDimMonitorAtten: Double = 0

    /// Monitor Mono fold-down — when on, the device sums L+R into both
    /// monitor outputs.  Useful for mono-compatibility checks while mixing.
    var monitorMono: Bool = false

    /// Mirror of the 18i20's hardware monitor section (front-panel volume
    /// knob + DIM/MUTE buttons).  Polled ~1 Hz while connected; read-only —
    /// the hardware owns these controls, the app just reflects them.
    var hwMonitor: HardwareMonitorState? = nil

    // MARK: - Output pair helpers

    /// Output pair groups the user has chosen to pin in the mixer, in
    /// profile order.
    var visibleOutputGroups: [(label: String, outputs: [PhysicalOutput])] {
        physicalOutputGroups.filter { visiblePairLabels.contains($0.label) }
    }

    /// The left output wValue of the first (Monitor) pair — the target of Dim.
    var monitorPairLeftWValue: UInt16 {
        physicalOutputGroups.first?.outputs.first?.wValue ?? 0
    }

    func pairAtten(leftWValue: UInt16) -> Double { pairAttens[leftWValue] ?? 0 }
    func outputMuted(_ wValue: UInt16) -> Bool { outputMutes[wValue] ?? false }

    private func pairMembers(leftWValue: UInt16) -> [UInt16] {
        physicalOutputGroups.first { $0.outputs.first?.wValue == leftWValue }?
            .outputs.map(\.wValue) ?? [leftWValue]
    }

    /// Per-USB-capture-channel routing — what the DAW sees on each of its
    /// input channels.  6 entries (DAW input 1..6).  Default values mirror
    /// what MixControl applies on first launch: capture 1..4 = Analog 1..4,
    /// capture 5..6 = S/PDIF 1..2.  Persisted to UserDefaults like routes.
    var captureRoutes: [Int: MixBus] = [
        0: .analog1, 1: .analog2, 2: .analog3, 3: .analog4,
        4: .spdif1,  5: .spdif2,
    ]

    // Matrix mixer: 18 input channels × N mix buses (6 or 8, per profile.mixBusCount).  The user-
    // facing knobs are `mixerLevels` + `mixerPans` + `mixerMutes` +
    // `mixerSolos`.  The per-cell gain actually sent to the device is
    // computed on demand by `effectiveGain(...)` from those four fields.
    var mixerSources: [SignalSource] = Array(repeating: .off, count: 18)
    /// One fader value per channel per stereo bus pair (M1+M2, M3+M4, M5+M6).
    /// Range -60…+6 dB, default 0.
    var mixerLevels: [[Double]] = Array(repeating: Array(repeating: 0, count: 3), count: 18)
    /// One pan position per channel per stereo bus pair. -1 = full left,
    /// 0 = center (no attenuation either side), +1 = full right.
    var mixerPans:   [[Double]] = Array(repeating: Array(repeating: 0, count: 3), count: 18)
    /// Per-channel mute — silences the channel's contribution to every
    /// mix bus.  Matches how M behaves on a real mixer / in MixControl.
    var mixerMutes: [Bool] = Array(repeating: false, count: 18)
    /// Per-channel solo.  When any channel is soloed, every non-soloed
    /// channel goes silent on every bus.
    var mixerSolos: [Bool] = Array(repeating: false, count: 18)
    /// User-set custom names per matrix channel. Empty string = use default "Ch N".
    var mixerNames: [String]   = Array(repeating: "", count: 18)
    /// Indices of the LEFT channel of each linked stereo pair.  Channels are
    /// grouped into fixed even/odd pairs: (0,1), (2,3), (4,5), …, (16,17).
    /// If `linkedPairs.contains(0)`, channels 0 and 1 are linked.
    var linkedPairs: Set<Int>  = []

    /// User-saved presets (full snapshots of routes + matrix + names + links).
    var presets: [ScarlettPreset] = []

    /// Set true once at startup if we detected a first launch (no
    /// UserDefaults state yet).  ContentView observes this and prompts
    /// the user with a choice between "apply default config" and "keep
    /// whatever's already on the device".  Cleared after either choice.
    var showFirstLaunchPrompt: Bool = false

    /// Capped event log — surfaced in the Device tab.  Newest first.
    var deviceEvents: [DeviceEvent] = []
    @ObservationIgnored private let maxEvents = 100
    @ObservationIgnored private var coreAudioListenerInstalled = false
    @ObservationIgnored private var lastCoreAudioPresence: Bool = false
    var selectedBus: MixBus = .m1 {
        didSet {
            if !restoringProfileState { saveSelectedBus() }
        }
    }

    init() {
        installCoreAudioListener()
        // Defer USB work so the window can appear before we sync-read the
        // matrix (100+ control transfers when a device is connected).
        Task { @MainActor in
            attemptConnect()
        }
    }

    /// Try to (re-)open the device and refresh all state.  Idempotent.
    /// On success: switches to `.connected` and re-pushes persisted routes.
    /// On `deviceNotFound`: switches to `.waiting` (silent — happens at idle).
    /// On any other failure: switches to `.disconnected(reason)`.
    func attemptConnect() {
        let wasConnected = isConnected
        do {
            let dev = try ScarlettDevice()
            guard dev.profile.isSupported else {
                self.device = nil
                if connection != .unsupported(dev.profile) {
                    logEvent(.warning, "Connection",
                             "Detected \(dev.profile.displayName) — not supported in this build")
                }
                connection = .unsupported(dev.profile)
                return
            }
            self.device = dev
            restoringProfileState = true
            prepareState(for: dev.profile)
            if let bcd = dev.firmwareBCD() {
                let hi = (bcd >> 8) & 0xff
                let lo = bcd & 0xff
                let major = (hi >> 4) * 10 + (hi & 0xf)
                let minor = (lo >> 4) * 10 + (lo & 0xf)
                self.firmware = String(format: "v%d.%02d", major, minor)
            }
            self.serial = dev.serialNumber() ?? "—"
            refreshFromDevice()
            loadPersistedState()
            restoringProfileState = false
            ensurePinnedDawChannels()
            if !wasConnected {
                logEvent(.info, "Connection",
                         "Connected to \(dev.profile.displayName) (firmware \(firmware), serial \(serial))")
            }
            connection = .connected
        } catch ScarlettError.deviceNotFound {
            restoringProfileState = false
            self.device = nil
            // Clear meters so we don't show stale levels frozen from before.
            peaks = .empty
            peaksHeld = .empty
            if wasConnected {
                logEvent(.warning, "Connection", "Device went away")
                connection = .disconnected("Device not found")
            } else if connection != .waiting {
                // Came back from disconnect → return to waiting until we find it.
                connection = .waiting
            }
        } catch {
            restoringProfileState = false
            self.device = nil
            peaks = .empty
            peaksHeld = .empty
            if connection != .disconnected("\(error)") {
                logEvent(.error, "Connection", "Open device failed: \(error)")
            }
            connection = .disconnected("\(error)")
        }
    }

    /// Returns true if the IOKit error code looks like a device that's gone
    /// (unplugged, hung, or otherwise un-talkable to).  Anything else is
    /// treated as a transient that we'll just retry.
    private static func isDisconnectError(_ err: Swift.Error) -> Bool {
        guard let e = err as? ScarlettError,
              case let .ioReturn(_, code) = e else { return false }
        return code == kIOReturnNoDevice
            || code == kIOReturnNotAttached
            || code == kIOReturnNotResponding
            || code == kIOReturnAborted
    }

    // MARK: - Event log

    func logEvent(_ severity: DeviceEvent.Severity, _ category: String, _ message: String) {
        let event = DeviceEvent(timestamp: Date(), severity: severity,
                                category: category, message: message)
        deviceEvents.insert(event, at: 0)
        if deviceEvents.count > maxEvents { deviceEvents.removeLast() }
    }

    func clearDeviceEvents() { deviceEvents = [] }

    // MARK: - Core Audio device presence

    /// Listen for the Scarlett appearing in or disappearing from Core Audio's
    /// device list. Independent from USB polling — even if USB transfers keep
    /// succeeding, this catches cases where macOS's audio HAL drops the
    /// device (or it shows up after a hot-plug).
    private func installCoreAudioListener() {
        guard !coreAudioListenerInstalled else { return }
        coreAudioListenerInstalled = true
        lastCoreAudioPresence = Self.scarlettPresentInCoreAudio()

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let present = Self.scarlettPresentInCoreAudio()
            Task { @MainActor in
                guard present != self.lastCoreAudioPresence else { return }
                self.lastCoreAudioPresence = present
                if present {
                    self.logEvent(.info, "Core Audio",
                                  "\(self.profile.displayName) visible to Core Audio")
                    // Device just appeared — kick a connect attempt so we
                    // don't wait the full 2 s for the polling loop's retry.
                    if !self.isConnected { self.attemptConnect() }
                } else {
                    self.logEvent(.warning, "Core Audio",
                                  "\(self.profile.displayName) disappeared from Core Audio device list")
                    if self.isConnected {
                        self.device = nil
                        self.connection = .disconnected("Removed from Core Audio")
                        self.peaks = .empty
                        self.peaksHeld = .empty
                    }
                }
            }
        }
        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, DispatchQueue.main, listener
        )
    }

    private static func scarlettPresentInCoreAudio() -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr, size > 0 else { return false }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
        ) == noErr else { return false }
        return ids.contains { deviceNameContainsScarlett($0) }
    }

    private static func deviceNameContainsScarlett(_ id: AudioDeviceID) -> Bool {
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let kr = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &size, ptr)
        }
        guard kr == noErr, let cfName = name?.takeRetainedValue() as String? else {
            return false
        }
        return cfName.lowercased().contains("scarlett")
    }

    // MARK: - UserDefaults persistence
    //
    // We only persist the values that aren't reliably readable from the
    // device — namely the output routing (firmware bug: GETs return 00 00
    // regardless of what was SET, see memory: project-routing-get-unreliable)
    // and the user's last-selected matrix bus tab (small UX win).
    //
    // Everything else (gains, mutes, atten, clock, etc.) is reliably read on
    // launch via refreshFromDevice and doesn't need to be saved.

    private static let routesKeyPrefix        = "scarlett.routes.v2"
    private static let busTabKeyPrefix        = "scarlett.selectedBus.v2"
    private static let matrixKeyPrefix        = "scarlett.matrix.v2"
    private static let presetsKey             = "scarlett.presets.v1"
    private static let captureRoutesKeyPrefix = "scarlett.captureRoutes.v2"
    private static let monitorMonoKeyPrefix   = "scarlett.monitorMono.v2"
    private static let firstLaunchDoneKeyPrefix = "scarlett.firstLaunchCompleted.v2"
    private static let visibleOutputsKeyPrefix  = "scarlett.visibleOutputs.v1"

    private func routesKey(for profile: DeviceProfile) -> String {
        "\(Self.routesKeyPrefix).\(profile.productID)"
    }
    private func busTabKey(for profile: DeviceProfile) -> String {
        "\(Self.busTabKeyPrefix).\(profile.productID)"
    }
    private func matrixKey(for profile: DeviceProfile) -> String {
        "\(Self.matrixKeyPrefix).\(profile.productID)"
    }
    private func captureRoutesKey(for profile: DeviceProfile) -> String {
        "\(Self.captureRoutesKeyPrefix).\(profile.productID)"
    }
    private func monitorMonoKey(for profile: DeviceProfile) -> String {
        "\(Self.monitorMonoKeyPrefix).\(profile.productID)"
    }
    private func firstLaunchDoneKey(for profile: DeviceProfile) -> String {
        "\(Self.firstLaunchDoneKeyPrefix).\(profile.productID)"
    }
    private func visibleOutputsKey(for profile: DeviceProfile) -> String {
        "\(Self.visibleOutputsKeyPrefix).\(profile.productID)"
    }

    private func ensureMatrixSizing(for profile: DeviceProfile) {
        let pairs = profile.stereoPairCount
        if mixerLevels.count != 18 || mixerLevels.first?.count != pairs {
            mixerLevels = Array(repeating: Array(repeating: 0, count: pairs), count: 18)
            mixerPans   = Array(repeating: Array(repeating: 0, count: pairs), count: 18)
        }
    }

    /// Clear every value whose meaning or dimensions depend on the connected
    /// model.  Hardware reads and PID-scoped persistence are layered on top
    /// immediately afterwards.  This prevents an 8-bus device's M7/M8 and
    /// output destinations from leaking into a later 6-bus connection.
    private func prepareState(for profile: DeviceProfile) {
        routes = Dictionary(uniqueKeysWithValues:
            profile.physicalOutputs.map { ($0.wValue, MixBus.off) })
        captureRoutes = [:]
        selectedBus = profile.matrixOutputBuses.first ?? .m1

        pairAttens = [:]
        outputMutes = [:]
        // Default pinned output strips: the first two pairs (Monitor + the
        // next pair — Phones on the compact models, Line 3+4 on the 18i20).
        // The user can pin more from the mixer's Outputs menu.
        var order: [String] = []
        for out in profile.physicalOutputs where !order.contains(out.pairLabel) {
            order.append(out.pairLabel)
        }
        visiblePairLabels = Set(order.prefix(2))

        mixerSources = Array(repeating: .off, count: profile.matrixInputCount)
        mixerLevels = Array(
            repeating: Array(repeating: 0, count: profile.stereoPairCount),
            count: profile.matrixInputCount
        )
        mixerPans = Array(
            repeating: Array(repeating: 0, count: profile.stereoPairCount),
            count: profile.matrixInputCount
        )
        mixerMutes = Array(repeating: false, count: profile.matrixInputCount)
        mixerSolos = Array(repeating: false, count: profile.matrixInputCount)
        mixerNames = Array(repeating: "", count: profile.matrixInputCount)
        linkedPairs = []

        monitorMono = false
        hwMonitor = nil
        showFirstLaunchPrompt = false
        peaks = .empty
        peaksHeld = .empty
        peaksMax = .empty
        metersStale = false
    }

    private func ensureRouteSlots(for profile: DeviceProfile) {
        for out in profile.physicalOutputs where routes[out.wValue] == nil {
            routes[out.wValue] = .off
        }
    }

    /// Route helpers for the pinned Monitor / Phones master strips (wValue 0..3).
    func route(forOutput wValue: UInt16) -> MixBus { routes[wValue] ?? .off }

    func userSetRoute(wValue: UInt16, to source: MixBus) {
        routes[wValue] = source
        saveRoutes()
        guard let dev = device else { return }
        writeAsync { try? dev.setRouteSource(wValue: wValue, from: source) }
    }

    private struct PersistedMatrix: Codable {
        var levels: [[Double]]      // 18 × 3, per-channel-per-pair
        var pans: [[Double]]        // 18 × 3
        var mutes: [Bool]           // 18, per-channel
        var solos: [Bool]           // 18, per-channel
        var sources: [UInt8]        // 18, SignalSource.rawValue per channel
        var names: [String]         // 18
        var linkedLefts: [Int]      // left-channel indices of linked pairs
    }

    private func loadPersistedState() {
        let defaults = UserDefaults.standard
        let profile = self.profile
        ensureRouteSlots(for: profile)

        // Routes — re-push to device so it actually honors them.
        if let data = defaults.data(forKey: routesKey(for: profile)),
           let dict = try? JSONDecoder().decode([UInt16: UInt8].self, from: data) {
            let validOutputs = Set(profile.physicalOutputs.map(\.wValue))
            for (routeRaw, busRaw) in dict {
                guard validOutputs.contains(routeRaw),
                      let bus = MixBus(rawValue: busRaw),
                      profile.supportedWireByte(for: bus) != nil else { continue }
                routes[routeRaw] = bus
                if let dev = device {
                    writeAsync { try? dev.setRouteSource(wValue: routeRaw, from: bus) }
                }
            }
        }

        // Capture routes — load from UserDefaults but do NOT push at launch.
        if let data = defaults.data(forKey: captureRoutesKey(for: profile)),
           let dict = try? JSONDecoder().decode([UInt16: UInt8].self, from: data) {
            for (chRaw, busRaw) in dict {
                guard Int(chRaw) < profile.captureChannelCount + profile.loopbackChannelCount,
                      let bus = MixBus(rawValue: busRaw),
                      profile.supportedWireByte(for: bus) != nil else { continue }
                captureRoutes[Int(chRaw)] = bus
            }
        }

        monitorMono = defaults.bool(forKey: monitorMonoKey(for: profile))

        // Pinned output pairs — restore the user's choice, dropping labels
        // that don't exist on this profile (stale data from another build).
        if let saved = defaults.stringArray(forKey: visibleOutputsKey(for: profile)) {
            // The 18i8's headphone pairs were once labelled "Phones" and
            // "Line 5+6"; carry pins saved under the old names across.
            let renamed: [String: String] = profile == .scarlett18i8
                ? ["Phones": "Phones 1", "Line 5+6": "Phones 2"] : [:]
            let valid = Set(profile.physicalOutputs.map(\.pairLabel))
            let filtered = Set(saved.map { renamed[$0] ?? $0 }).intersection(valid)
            if !filtered.isEmpty { visiblePairLabels = filtered }
        }

        // Selected bus tab
        if let raw = defaults.object(forKey: busTabKey(for: profile)) as? UInt8,
           raw < UInt8(matrixBuses.count) {
            selectedBus = matrixBuses[Int(raw)]
        }

        let pairs = profile.stereoPairCount
        if let data = defaults.data(forKey: matrixKey(for: profile)),
           let m = try? JSONDecoder().decode(PersistedMatrix.self, from: data),
           m.levels.count == 18, m.levels.allSatisfy({ $0.count == pairs }),
           m.pans.count   == 18, m.pans.allSatisfy({ $0.count == pairs }),
           m.mutes.count  == 18, m.solos.count == 18,
           m.sources.count == 18, m.names.count == 18
        {
            mixerLevels = m.levels
            mixerPans = m.pans
            mixerMutes = m.mutes
            mixerSolos = m.solos
            mixerNames = m.names
            linkedPairs = Set(m.linkedLefts)
            for ch in 0..<18 {
                if let v = SignalSource(rawValue: m.sources[ch]),
                   profile.supportedWireByte(for: v) != nil {
                    mixerSources[ch] = v
                }
            }
            if device != nil {
                pushMatrixSourcesToDevice()
                for ch in 0..<18 {
                    for bus in matrixBuses {
                        pushCellGain(channel: ch, bus: bus)
                    }
                }
            }
        }

        if let data = defaults.data(forKey: Self.presetsKey),
           let decoded = try? JSONDecoder().decode([ScarlettPreset].self, from: data) {
            presets = decoded
        }

        if !defaults.bool(forKey: firstLaunchDoneKey(for: profile)) {
            showFirstLaunchPrompt = true
        }
    }

    /// Called when the user picks "Apply defaults" from the first-launch
    /// prompt.  Marks the prompt as resolved either way.
    func userCompleteFirstLaunch(applyDefaults: Bool) {
        if applyDefaults {
            userResetRoutingAndMatrix()
        }
        UserDefaults.standard.set(true, forKey: firstLaunchDoneKey(for: profile))
        showFirstLaunchPrompt = false
    }

    private func saveRoutes() {
        let validOutputs = Set(profile.physicalOutputs.map(\.wValue))
        let pairs: [(UInt16, UInt8)] = routes.compactMap { route, bus in
            guard validOutputs.contains(route), profile.supportedWireByte(for: bus) != nil else { return nil }
            return (route, bus.rawValue)
        }
        let dict = Dictionary(uniqueKeysWithValues: pairs)
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: routesKey(for: profile))
        }
    }

    private func saveCaptureRoutes() {
        let maxCount = profile.captureChannelCount + profile.loopbackChannelCount
        let pairs: [(UInt16, UInt8)] = captureRoutes.compactMap { channel, bus in
            guard (0..<maxCount).contains(channel), profile.supportedWireByte(for: bus) != nil else { return nil }
            return (UInt16(channel), bus.rawValue)
        }
        let dict = Dictionary(uniqueKeysWithValues: pairs)
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: captureRoutesKey(for: profile))
        }
    }

    private func saveMonitorMono() {
        UserDefaults.standard.set(monitorMono, forKey: monitorMonoKey(for: profile))
    }

    private func saveSelectedBus() {
        UserDefaults.standard.set(UInt8(selectedBus.matrixIndex ?? 0), forKey: busTabKey(for: profile))
    }

    private func saveMatrix() {
        let m = PersistedMatrix(
            levels: mixerLevels,
            pans: mixerPans,
            mutes: mixerMutes,
            solos: mixerSolos,
            sources: mixerSources.map { $0.rawValue },
            names: mixerNames,
            linkedLefts: Array(linkedPairs)
        )
        if let data = try? JSONEncoder().encode(m) {
            UserDefaults.standard.set(data, forKey: matrixKey(for: profile))
        }
    }

    private func savePresets() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.presetsKey)
        }
    }

    /// User-facing wrapper around `refreshFromDevice` — re-reads the
    /// device's matrix state into the view model and persists it.  Useful
    /// when another tool (or a power-cycle) has changed the device's
    /// flash and the UI is now out of sync.  Routing GETs always return
    /// 00 00 on the 1st-gen 8i6, so routes themselves aren't refreshed —
    /// only matrix sources / cell gains.
    func userLoadFromDevice() {
        guard device != nil else { return }
        refreshFromDevice()
        saveMatrix()
        logEvent(.info, "Refresh", "Matrix state reloaded from device")
    }

    /// Read all controls' current state from the device and update the
    /// view-model fields. Called on launch; can be called again to resync
    /// (e.g. after MixControl on Windows changed something out from under us).
    func refreshFromDevice() {
        guard let dev = device else { return }
        // Individual failures are swallowed — we keep the previously-stored
        // value for that field and continue. If everything fails the
        // connectionError will already have been raised by an earlier call.
        if let v = try? dev.getClockSource()              { clock = v }
        if let v = try? dev.getSampleRate()               { sampleRate = v }
        if let v = try? dev.getSyncLocked()               { syncLocked = v }
        if let v = try? dev.getImpedance(channel: 0)      { impedance1 = v }
        if let v = try? dev.getImpedance(channel: 1)      { impedance2 = v }
        if let v = try? dev.getHiLoGain(channel: 3)       { hi3 = v }
        if let v = try? dev.getHiLoGain(channel: 4)       { hi4 = v }
        if let v = try? dev.getMute(.master)              { masterMuted = v }
        // Read every physical output's gain stage (stage = wValue + 1).
        // Per-side mutes are kept as-is; the pair fader shows the L/R average.
        // Individual reads that fail (a stage the firmware doesn't back)
        // leave the previous value — same policy as every other read here.
        for group in physicalOutputGroups {
            var attens: [Double] = []
            // Only outputs with a functional stage — digital outs store
            // values without applying them, so reading those is noise.
            for out in group.outputs where profile.hasGainStage(wValue: out.wValue) {
                if let m = try? dev.getOutputMute(outputWValue: out.wValue) {
                    outputMutes[out.wValue] = m
                }
                if let a = try? dev.getOutputAttenuation(outputWValue: out.wValue) {
                    attens.append(a)
                }
            }
            if let left = group.outputs.first?.wValue, !attens.isEmpty {
                pairAttens[left] = attens.reduce(0, +) / Double(attens.count)
            }
        }
        // Routing GETs are still not trustworthy: byte 0x00 decodes to
        // .daw1, which is also what we'd get from a "null" 00 00 response.
        // We can't distinguish "device says DAW 1" from "device says
        // nothing" with a single read. Rely on UserDefaults to restore the
        // user's last routing — that's what loadPersistedState() does.
        // (A future protocol-fluency improvement: send a SET, read back, and
        // only trust GETs if the round-trip works.)

        // Matrix mixer reads correctly: 18 source reads + 18*6 = 108 gain
        // reads.  We pull them all into a local [[Double]] just long enough
        // to derive the user-facing level + pan model — there's no separate
        // persistent gains field.
        var snapshotGains: [[Double]] = Array(repeating: Array(repeating: 0, count: profile.mixBusCount),
                                              count: 18)
        for ch in 0..<18 {
            if let v = try? dev.getMixerSource(channel: ch) {
                mixerSources[ch] = v
            }
            for bus in matrixBuses {
                guard let idx = bus.matrixIndex else { continue }
                if let v = try? dev.getMixerGain(channel: ch, bus: bus) {
                    snapshotGains[ch][idx] = v
                }
            }
        }
        for ch in 0..<18 {
            for pair in 0..<stereoPairCount {
                let (level, pan) = Self.deriveLevelAndPan(
                    left:  snapshotGains[ch][pair * 2],
                    right: snapshotGains[ch][pair * 2 + 1]
                )
                mixerLevels[ch][pair] = level
                mixerPans[ch][pair] = pan
            }
        }
    }

    // MARK: - Meter polling

    func startMeterPolling() {
        Task { @MainActor [weak self] in
            var lastTick = Date()
            while !Task.isCancelled {
                guard let self else { return }

                // Not connected → periodically retry opening the device.
                guard let dev = self.device, self.isConnected else {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self.attemptConnect()
                    lastTick = Date()
                    continue
                }

                // Keep polling whenever the window is visible on screen —
                // even if our app isn't the frontmost — so a user can park
                // the meter window behind something else and still watch it.
                // Only back off when the window is genuinely hidden:
                // minimised to dock, or the app itself hidden (Cmd+H).
                let windowVisible = NSApp.windows.contains { win in
                    win.occlusionState.contains(.visible) && !win.isMiniaturized
                }
                if NSApp.isHidden || !windowVisible {
                    try? await Task.sleep(nanoseconds: 500_000_000)   // 2 Hz
                    lastTick = Date()
                    continue
                }
                let now = Date()
                let elapsed = now.timeIntervalSince(lastTick)
                lastTick = now
                let decay = self.peakDecayDbPerSecond * elapsed

                do {
                    let p = try dev.readPeaks()
                    if self.metersStale {
                        self.logEvent(.info, "USB", "Meter polling resumed")
                    }
                    self.peaks = p
                    // (no need to re-assign `connection` here — by the time
                    // we're successfully reading peaks we're already in
                    // .connected; `attemptConnect()` sets it.)

                    // Mutate in-place rather than allocating 6 new arrays per
                    // poll via zip+map. CoW means a single backing-store copy
                    // at most, and the SwiftUI @Observable notification fires
                    // once when we re-assign each top-level field.
                    var held = self.peaksHeld
                    var max_ = self.peaksMax
                    // Size the held/max stores to this device (they start at the
                    // fixed-size `.empty` = 8 daw / 8 mixer, but `p` is sized per
                    // device: daw 6..20, mixer 6..8). Resizing on the first poll
                    // (and any device change) gives the 18i20 its full 20 daw
                    // meters and — with the `min` bounds below — makes it
                    // impossible to read `p` out of range on 8i6/18i6/6i6.
                    if held.daw.count   != p.daw.count   { held.daw   = Array(repeating: -.infinity, count: p.daw.count) }
                    if max_.daw.count   != p.daw.count   { max_.daw   = Array(repeating: -.infinity, count: p.daw.count) }
                    if held.mixer.count != p.mixer.count { held.mixer = Array(repeating: -.infinity, count: p.mixer.count) }
                    if max_.mixer.count != p.mixer.count { max_.mixer = Array(repeating: -.infinity, count: p.mixer.count) }
                    for i in 0..<min(held.inputs.count, p.inputs.count) { held.inputs[i] = max(p.inputs[i], held.inputs[i] - decay) }
                    for i in 0..<min(held.daw.count,    p.daw.count)    { held.daw[i]    = max(p.daw[i],    held.daw[i]    - decay) }
                    for i in 0..<min(held.mixer.count,  p.mixer.count)  { held.mixer[i]  = max(p.mixer[i],  held.mixer[i]  - decay) }
                    for i in 0..<min(max_.inputs.count, p.inputs.count) { max_.inputs[i] = max(p.inputs[i], max_.inputs[i]) }
                    for i in 0..<min(max_.daw.count,    p.daw.count)    { max_.daw[i]    = max(p.daw[i],    max_.daw[i]) }
                    for i in 0..<min(max_.mixer.count,  p.mixer.count)  { max_.mixer[i]  = max(p.mixer[i],  max_.mixer[i]) }
                    self.peaksHeld = held
                    self.peaksMax  = max_

                    self.metersStale = false
                } catch {
                    if !self.metersStale {
                        self.logEvent(.warning, "USB", "Meter polling failed: \(error)")
                    }
                    self.metersStale = true
                    if Self.isDisconnectError(error) {
                        self.logEvent(.error, "Connection", "Device disconnected during transfer")
                        self.device = nil
                        self.connection = .disconnected("\(error)")
                        self.peaks = .empty
                        self.peaksHeld = .empty
                        continue
                    }
                }

                // Re-read sync status roughly every second so the indicator
                // catches clock drops without doing a USB transfer every tick.
                self.syncPollAccumulator += elapsed
                if self.syncPollAccumulator >= 1.0 {
                    self.syncPollAccumulator = 0
                    if let s = try? dev.getSyncLocked() {
                        if s != self.syncLocked {
                            self.logEvent(
                                s ? .info : .warning,
                                "Clock",
                                s ? "Clock locked" : "Clock lost lock"
                            )
                        }
                        self.syncLocked = s
                    }
                }

                // Mirror the hardware monitor section (18i20 front-panel
                // knob + DIM/MUTE) every tick so the fader tracks the knob
                // smoothly. One extra 4-byte transfer per poll — cheap.
                if self.profile.hasHardwareMonitorControls,
                   let hw = try? dev.getHardwareMonitorControls() {
                    if let old = self.hwMonitor {
                        if old.dim != hw.dim {
                            self.logEvent(.info, "Monitor",
                                hw.dim ? "Hardware Dim engaged" : "Hardware Dim released")
                        }
                        if old.mute != hw.mute {
                            self.logEvent(.info, "Monitor",
                                hw.mute ? "Hardware Mute engaged" : "Hardware Mute released")
                        }
                    }
                    if self.hwMonitor != hw { self.hwMonitor = hw }
                }

                // 83 ms ≈ 12 Hz. Each readPeaks() does 3 USB control transfers
                // (inputs/DAW/mixer) which aren't free on macOS — kernel
                // transitions ~1-5 ms each — so polling alone is most of our
                // idle CPU. 12 Hz still looks smooth and roughly halves CPU
                // vs the 20 Hz default we started with.
                try? await Task.sleep(nanoseconds: 83_000_000)
            }
        }
    }

    // MARK: - User actions (every public mutator goes through here so we
    // can ignore programmatic updates and surface errors uniformly)

    /// Set the fader for one output pair (identified by its left wValue) —
    /// pushes the same attenuation to every output in the pair.
    /// No-op on pairs without a functional gain stage (digital outs).
    func userSetPairAtten(leftWValue: UInt16, db: Double) {
        guard profile.hasGainStage(wValue: leftWValue) else { return }
        pairAttens[leftWValue] = db
        guard let dev = device else { return }
        let members = pairMembers(leftWValue: leftWValue)
        writeAsync {
            for wv in members {
                try? dev.setOutputAttenuation(outputWValue: wv, db: db)
            }
        }
    }

    /// Mute/unmute one physical output (one side of a pair).
    /// No-op on outputs without a functional gain stage (digital outs).
    func userSetOutputMute(wValue: UInt16, muted: Bool) {
        guard profile.hasGainStage(wValue: wValue) else { return }
        outputMutes[wValue] = muted
        guard let dev = device else { return }
        writeAsync { try? dev.setOutputMute(outputWValue: wValue, muted: muted) }
    }

    /// Show/hide an output pair's pinned strip.
    func userToggleOutputPairVisible(label: String) {
        if visiblePairLabels.contains(label) {
            visiblePairLabels.remove(label)
        } else {
            visiblePairLabels.insert(label)
        }
        UserDefaults.standard.set(Array(visiblePairLabels),
                                  forKey: visibleOutputsKey(for: profile))
    }

    func userSetMasterMute(_ muted: Bool) {
        masterMuted = muted
        guard let dev = device else { return }
        writeAsync { try? dev.setMute(.master, muted: muted) }
    }

    // MARK: - Input switches

    func userSetImpedance(channel: Int, mode: Impedance) {
        if channel == 1 { impedance1 = mode } else if channel == 2 { impedance2 = mode }
        guard let dev = device else { return }
        writeAsync { try? dev.setImpedance(channel: channel - 1, mode: mode) }
    }

    func userSetHiLo(channel: Int, hi: Bool) {
        if channel == 3 { hi3 = hi } else if channel == 4 { hi4 = hi }
        guard let dev = device else { return }
        writeAsync { try? dev.setHiLoGain(channel: channel, hi: hi) }
    }

    // MARK: - Routing

    func userSetRoute(_ route: Route, to source: MixBus) {
        userSetRoute(wValue: route.rawValue, to: source)
    }

    /// Set what the DAW sees on USB capture channel `channel`.  Persists and pushes to the device.
    func userSetCaptureRoute(channel: Int, to source: MixBus) {
        let maxCh = profile.captureChannelCount + profile.loopbackChannelCount - 1
        guard (0...maxCh).contains(channel) else { return }
        captureRoutes[channel] = source
        saveCaptureRoutes()
        guard let dev = device else { return }
        writeAsync { try? dev.setCaptureRoute(channel: channel, from: source) }
    }

    // MARK: - Monitor mono

    func userSetMonitorMono(_ enabled: Bool) {
        monitorMono = enabled
        saveMonitorMono()
        guard let dev = device else { return }
        // MixControl's setMonMono loops over 5 output pairs, writing the
        // user's desired value to pair 1 (the active one for Monitor) and
        // 0 to the rest.  We replicate the full sequence with a small
        // inter-write delay because the 1st-gen 8i6's firmware stalls if
        // it gets 5 control transfers in rapid succession.
        writeAsync {
            for pair in 1...5 {
                let value = (pair == 1) ? enabled : false
                try? dev.setMonitorMono(pair: pair, enabled: value)
                Thread.sleep(forTimeInterval: 0.02)   // 20 ms between writes
            }
        }
        logEvent(.info, "Mono", enabled ? "Monitor mono on" : "Monitor mono off")
    }


    // MARK: - Device config

    func userSetClock(_ src: ClockSource) {
        clock = src
        guard let dev = device else { return }
        writeAsync { try? dev.setClockSource(src) }
    }

    func userSetSampleRate(_ hz: UInt32) {
        sampleRate = hz
        guard let dev = device else { return }
        writeAsync { try? dev.setSampleRate(hz) }
    }

    // MARK: - Matrix mixer

    /// Computes the gain we actually want the device to apply for a cell,
    /// taking mute and solo into account.
    /// - Mute: cell is silenced (-128 dB).
    /// - Solo in bus: any cell soloed in this bus → all non-soloed cells in
    ///   the same bus are silenced.
    /// - Otherwise: derived from `mixerLevels` + `mixerPans` for the bus pair
    ///   this bus belongs to.
    func effectiveGain(channel: Int, busIdx: Int) -> Double {
        // Per-channel mute / solo: a single boolean per channel applies
        // to *every* bus this channel feeds.
        if mixerMutes[channel] { return -128 }
        let soloActive = mixerSolos.contains(true)
        if soloActive && !mixerSolos[channel] { return -128 }
        let pair = busIdx / 2
        let isLeft = busIdx % 2 == 0
        return Self.cellGain(level: mixerLevels[channel][pair],
                             pan: mixerPans[channel][pair],
                             isLeft: isLeft)
    }

    // MARK: - Level + pan math

    /// Convert a (level, pan, side) triple into the per-cell gain that the
    /// device's matrix mixer will use.  "Amp-style" pan law: at center both
    /// sides get the full level; panning hard to one side reduces the other
    /// to -∞ without attenuating the chosen side.
    static func cellGain(level: Double, pan: Double, isLeft: Bool) -> Double {
        let clamped = max(-1, min(1, pan))
        let factor: Double = isLeft
            ? (clamped <= 0 ? 1.0 : 1.0 - clamped)
            : (clamped >= 0 ? 1.0 : 1.0 + clamped)
        if factor <= 0.0001 { return -128 }
        return level + 20 * log10(factor)
    }

    /// Inverse of `cellGain` — recover a (level, pan) pair from the device's
    /// current L and R cell gains.  Used to migrate the matrix on launch.
    static func deriveLevelAndPan(left: Double, right: Double) -> (level: Double, pan: Double) {
        let safeL = left.isFinite  ? max(-128, left)  : -128
        let safeR = right.isFinite ? max(-128, right) : -128
        if abs(safeL - safeR) < 0.5 {
            return (max(safeL, safeR), 0)
        }
        if safeL > safeR {
            let level = safeL
            // pan in [-1, 0]: gain_R = level + 20·log10(1 + pan)
            let pan = pow(10, (safeR - level) / 20) - 1
            return (level, max(-1, pan))
        } else {
            let level = safeR
            // pan in (0, 1]: gain_L = level + 20·log10(1 - pan)
            let pan = 1 - pow(10, (safeL - level) / 20)
            return (level, min(1, pan))
        }
    }

    // Kept as static thunks for source compatibility with existing callers —
    // they just defer to MixBus's own computed properties.
    static func pairIndex(of bus: MixBus) -> Int { bus.stereoPairIndex ?? 0 }
    static func isLeftSide(of bus: MixBus) -> Bool { bus.isLeftOfPair }

    func userSetMixerSource(channel: Int, source: SignalSource) {
        guard (0..<18).contains(channel) else { return }
        // Steal the source from any other channel that holds it.  Contrary to
        // x42's notes, the firmware accepts double-assignment — confirmed on
        // the 18i20 (leftover flash state had DAW 3 on two channels) and the
        // 8i6 (a second DAW 1 channel measured +6 dB on the mix meter).  A
        // duplicate silently double-feeds every bus, making the visible
        // channel's fader appear dead.
        if source != .off {
            for ch in 0..<18 where ch != channel && mixerSources[ch] == source {
                mixerSources[ch] = .off
                if let dev = device {
                    writeAsync { try? dev.setMixerSource(channel: ch, source: .off) }
                }
            }
        }
        mixerSources[channel] = source
        saveMatrix()
        guard let dev = device else { return }
        writeAsync { try? dev.setMixerSource(channel: channel, source: source) }
    }

    // MARK: - Pinned DAW return
    //
    // Matrix channels 14 & 15 are reserved as the "DAW return" controlled by
    // `PinnedDawStrip` (the column pinned to the left of the matrix). They
    // are sourced from DAW 1 and DAW 2 respectively, hard-panned to opposite
    // sides of every bus pair, and marked as a linked stereo pair so fader /
    // mute changes on one mirror to the other automatically.
    //
    // Re-asserted on every successful connect — if the device was power-cycled
    // or somebody else changed those channels, we put them back the way the
    // UI expects.

    /// Channel indices of the pinned DAW pair.
    public static let pinnedDawLeftChannel: Int  = 14
    public static let pinnedDawRightChannel: Int = 15

    /// True when this device reserves matrix channels 14+15 as the pinned
    /// "DAW return" strip.  Only the compact models (8i6/6i6) do: their
    /// physical inputs fit in the first 14 strips, channels 14-17 aren't on
    /// screen, and DAW 1/2 is the Mac's system-audio output — worth a
    /// dedicated return fader.  The 18-input models show all 18 channels as
    /// regular strips, so nothing is reserved and every DAW playback pair is
    /// wired like any other source.
    var hasPinnedDawReturn: Bool {
        profile.sources.filter {
            $0.category == .analog || $0.category == .digital
        }.count <= 14
    }

    private func ensurePinnedDawChannels() {
        guard hasPinnedDawReturn else { return }
        let l = Self.pinnedDawLeftChannel
        let r = Self.pinnedDawRightChannel

        // Claim DAW 1/2, disconnecting any other channel holding them —
        // the device would otherwise play them twice (see userSetMixerSource).
        assignPinnedSource(channel: l, source: .daw1)
        assignPinnedSource(channel: r, source: .daw2)

        for pair in 0..<stereoPairCount {
            if mixerPans[l][pair] != -1 { userSetMixerPan(channel: l, pair: pair, pan: -1) }
            if mixerPans[r][pair] !=  1 { userSetMixerPan(channel: r, pair: pair, pan:  1) }
        }
        if !linkedPairs.contains(l) {
            linkedPairs.insert(l)
            saveMatrix()
        }
    }

    /// Helper for `ensurePinnedDawChannels`: claim a specific source for one
    /// channel, disconnecting it from any other channel that currently holds
    /// it.  Skips work if the target already has the desired source.
    private func assignPinnedSource(channel target: Int, source desired: SignalSource) {
        guard (0..<18).contains(target) else { return }
        if mixerSources[target] == desired { return }

        // Disconnect any other channel that currently has this source —
        // otherwise the device plays it on both channels.
        for ch in 0..<18 where ch != target && mixerSources[ch] == desired {
            userSetMixerSource(channel: ch, source: .off)
        }

        // Now claim it on the target.  These writes are queued on the same
        // serial USB queue, so the disconnect above lands before the new
        // assignment hits the device.
        userSetMixerSource(channel: target, source: desired)
    }

    // MARK: - Stereo link

    /// Fixed even/odd partner index for a given channel.
    private static func leftOfPair(_ ch: Int) -> Int { ch - (ch % 2) }

    func isLinked(_ ch: Int) -> Bool {
        linkedPairs.contains(Self.leftOfPair(ch))
    }

    func linkedPartner(_ ch: Int) -> Int? {
        guard isLinked(ch) else { return nil }
        return ch % 2 == 0 ? ch + 1 : ch - 1
    }

    /// Linking pans the pair hard L/R on every bus; unlinking centers both
    /// channels — same as Focusrite MixControl.
    func userToggleLink(channel ch: Int) {
        let left = Self.leftOfPair(ch)
        let linking = !linkedPairs.contains(left)
        if linking {
            linkedPairs.insert(left)
        } else {
            linkedPairs.remove(left)
        }
        for pair in 0..<stereoPairCount {
            mixerPans[left][pair]     = linking ? -1 : 0
            mixerPans[left + 1][pair] = linking ?  1 : 0
            pushBusPair(channel: left, pair: pair)
            pushBusPair(channel: left + 1, pair: pair)
        }
        saveMatrix()
    }

    /// Set the channel-level fader for one stereo bus pair. Pushes both cells
    /// (L and R) in that pair to the device.  If the channel is in a linked
    /// stereo pair, the partner's level for the same pair moves with it.
    func userSetMixerLevel(channel: Int, pair: Int, level: Double) {
        guard (0..<18).contains(channel), (0..<stereoPairCount).contains(pair) else { return }
        mixerLevels[channel][pair] = level
        pushBusPair(channel: channel, pair: pair)
        if let partner = linkedPartner(channel) {
            mixerLevels[partner][pair] = level
            pushBusPair(channel: partner, pair: pair)
        }
        saveMatrix()
    }

    /// Set the L↔R pan for one stereo bus pair on one channel. Snaps to
    /// center when within ±0.04.  A linked partner mirrors the pan, so the
    /// pair's width stays symmetric.
    func userSetMixerPan(channel: Int, pair: Int, pan: Double) {
        guard (0..<18).contains(channel), (0..<stereoPairCount).contains(pair) else { return }
        let snapped = abs(pan) < 0.04 ? 0 : max(-1, min(1, pan))
        mixerPans[channel][pair] = snapped
        pushBusPair(channel: channel, pair: pair)
        if let partner = linkedPartner(channel) {
            mixerPans[partner][pair] = -snapped
            pushBusPair(channel: partner, pair: pair)
        }
        saveMatrix()
    }

    private func pushBusPair(channel: Int, pair: Int) {
        let outs = matrixBuses
        let leftIdx = pair * 2
        let rightIdx = pair * 2 + 1
        guard leftIdx < outs.count, rightIdx < outs.count else { return }
        pushCellGain(channel: channel, bus: outs[leftIdx])
        pushCellGain(channel: channel, bus: outs[rightIdx])
    }

    func userSetChannelName(channel: Int, name: String) {
        guard (0..<18).contains(channel) else { return }
        mixerNames[channel] = name
        saveMatrix()
    }

    /// Reset the all-time max peaks for every source.
    func clearMaxPeaks() {
        peaksMax = .empty
    }

    /// Reset the all-time max peak for one signal source / mix-bus source.
    /// Both old call-sites (`forSource`, `forMixBus`) collapse into this one
    /// once we map a `SignalSource` to its `MixBus` equivalent.
    func clearMaxPeak(_ source: MixBus) {
        guard source != .off else { return }
        // Resolve the meter slot the same way `PeakReading.level(for:profile:)`
        // does — by the device's wire byte — so this works for every source on
        // every profile (incl. the 18i20's DAW 13-20 and M7/M8) and stays in
        // bounds regardless of how the peak arrays are sized.
        let byte = profile.wireByte(for: source)
        if let idx = profile.dawMeterIndex(forByte: byte), idx < peaksMax.daw.count {
            peaksMax.daw[idx] = -.infinity
        } else if let idx = profile.inputMeterIndex(forByte: byte), idx < peaksMax.inputs.count {
            peaksMax.inputs[idx] = -.infinity
        } else if let idx = profile.mixMeterIndex(forByte: byte), idx < peaksMax.mixer.count {
            peaksMax.mixer[idx] = -.infinity
        }
    }

    /// Convenience wrapper so `SignalSource`-typed call-sites (matrix-channel
    /// strips) don't need to construct a `MixBus` themselves.  Every valid
    /// `SignalSource` has the same raw byte value in `MixBus`.
    func clearMaxPeak(forSource source: SignalSource) {
        clearMaxPeak(MixBus(rawValue: source.rawValue) ?? .off)
    }

    // MARK: - Presets

    /// Old presets predate product metadata. At that time only the 6-bus 8i6
    /// and 8-bus 18i8 could create them, so the saved pair count is a safe
    /// migration discriminator. Newer untagged experimental presets fail
    /// closed instead of being guessed onto another device.
    func effectiveProductID(for preset: ScarlettPreset) -> UInt16? {
        if let productID = preset.productID { return productID }
        guard let pairCount = preset.mixerLevels.first?.count else { return nil }
        switch pairCount {
        case DeviceProfile.scarlett8i6.stereoPairCount:
            return DeviceProfile.scarlett8i6.productID
        case DeviceProfile.scarlett18i8.stereoPairCount:
            return DeviceProfile.scarlett18i8.productID
        default:
            return nil
        }
    }

    func presetDeviceLabel(_ preset: ScarlettPreset) -> String {
        guard let pid = effectiveProductID(for: preset) else { return "Legacy — unknown device" }
        return DeviceProfile.forProductID(pid)?.displayName ?? String(format: "Unknown device (0x%04x)", pid)
    }

    private func snapshotRoutes() -> [UInt16: MixBus] {
        let validOutputs = Set(profile.physicalOutputs.map(\.wValue))
        return routes.filter { route, bus in
            validOutputs.contains(route) && profile.supportedWireByte(for: bus) != nil
        }
    }

    private func validate(_ preset: ScarlettPreset, for profile: DeviceProfile) throws {
        if let version = preset.schemaVersion,
           version > ScarlettPreset.currentSchemaVersion {
            throw ScarlettPresetError.invalid("schema version \(version) is newer than this app supports")
        }
        if preset.schemaVersion != nil && preset.productID == nil {
            throw ScarlettPresetError.invalid("device metadata is missing")
        }

        guard let presetPID = effectiveProductID(for: preset) else {
            throw ScarlettPresetError.unknownLegacyDevice
        }
        guard presetPID == profile.productID else {
            let presetName = DeviceProfile.forProductID(presetPID)?.displayName
                ?? String(format: "device 0x%04x", presetPID)
            throw ScarlettPresetError.deviceMismatch(
                preset: presetName,
                connected: profile.displayName
            )
        }

        let validOutputs = Set(profile.physicalOutputs.map(\.wValue))
        for (route, rawSource) in preset.routes {
            guard validOutputs.contains(route) else {
                throw ScarlettPresetError.invalid("output route \(route) does not exist")
            }
            guard let source = MixBus(rawValue: rawSource),
                  profile.supportedWireByte(for: source) != nil else {
                throw ScarlettPresetError.invalid("output route \(route) uses an unsupported source")
            }
        }

        guard preset.mixerSources.count == profile.matrixInputCount else {
            throw ScarlettPresetError.invalid("matrix source count is not \(profile.matrixInputCount)")
        }
        for rawSource in preset.mixerSources {
            guard let source = SignalSource(rawValue: rawSource),
                  profile.supportedWireByte(for: source) != nil else {
                throw ScarlettPresetError.invalid("the matrix contains an unsupported source")
            }
        }

        let rows = profile.matrixInputCount
        let pairs = profile.stereoPairCount
        guard preset.mixerLevels.count == rows,
              preset.mixerLevels.allSatisfy({ $0.count == pairs }),
              preset.mixerPans.count == rows,
              preset.mixerPans.allSatisfy({ $0.count == pairs }) else {
            throw ScarlettPresetError.invalid("matrix dimensions do not match \(profile.displayName)")
        }
        guard preset.mixerMutes.count == rows,
              preset.mixerSolos.count == rows,
              preset.mixerNames.count == rows else {
            throw ScarlettPresetError.invalid("matrix channel metadata is incomplete")
        }
        guard preset.linkedLefts.allSatisfy({ $0 >= 0 && $0 < rows - 1 && $0.isMultiple(of: 2) }) else {
            throw ScarlettPresetError.invalid("stereo-link indices are invalid")
        }
        guard Int(preset.selectedBus) < profile.mixBusCount else {
            throw ScarlettPresetError.invalid("selected mix bus does not exist")
        }
    }

    func userSavePreset(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let snapshot = ScarlettPreset(
            id: UUID(),
            name: trimmed,
            createdAt: Date(),
            schemaVersion: ScarlettPreset.currentSchemaVersion,
            productID: profile.productID,
            routes: Dictionary(uniqueKeysWithValues:
                snapshotRoutes().map { ($0.key, $0.value.rawValue) }),
            mixerSources: mixerSources.map { $0.rawValue },
            mixerLevels: mixerLevels,
            mixerPans: mixerPans,
            mixerMutes: mixerMutes,
            mixerSolos: mixerSolos,
            mixerNames: mixerNames,
            linkedLefts: Array(linkedPairs),
            selectedBus: UInt8(selectedBus.matrixIndex ?? 0)
        )

        // Replace any preset with the same name; otherwise append.
        if let idx = presets.firstIndex(where: {
            $0.name == trimmed && effectiveProductID(for: $0) == profile.productID
        }) {
            presets[idx] = snapshot
        } else {
            presets.append(snapshot)
        }
        savePresets()
    }

    func userLoadPreset(_ preset: ScarlettPreset) throws {
        guard let dev = device else { return }
        try validate(preset, for: dev.profile)

        // Routes
        for (routeRaw, busRaw) in preset.routes {
            guard let bus = MixBus(rawValue: busRaw) else { continue }
            routes[routeRaw] = bus
            writeAsync { try? dev.setRouteSource(wValue: routeRaw, from: bus) }
        }
        saveRoutes()

        // Matrix sources.  The firmware accepts the same source on two
        // channels and double-feeds every bus, so drop duplicates from older
        // presets: the first channel holding a source keeps it.
        if preset.mixerSources.count == 18 {
            var claimed = Set<SignalSource>()
            for ch in 0..<18 {
                guard let saved = SignalSource(rawValue: preset.mixerSources[ch]) else { continue }
                let src = (saved != .off && !claimed.insert(saved).inserted) ? .off : saved
                mixerSources[ch] = src
                writeAsync { try? dev.setMixerSource(channel: ch, source: src) }
            }
        }

        // Apply mutes / solos / levels / pans / names / links before
        // pushing cells so `effectiveGain` sees the right state.
        if preset.mixerMutes.count == 18 { mixerMutes = preset.mixerMutes }
        if preset.mixerSolos.count == 18 { mixerSolos = preset.mixerSolos }
        if preset.mixerLevels.count == 18, preset.mixerLevels.allSatisfy({ $0.count == stereoPairCount }) {
            mixerLevels = preset.mixerLevels
        }
        if preset.mixerPans.count == 18, preset.mixerPans.allSatisfy({ $0.count == stereoPairCount }) {
            mixerPans = preset.mixerPans
        }
        if preset.mixerNames.count == 18 { mixerNames = preset.mixerNames }
        linkedPairs = Set(preset.linkedLefts)

        // Re-claim DAW 1/2 for the pinned strip, as on connect — a preset
        // may have them on regular channels or not at all.
        ensurePinnedDawChannels()

        for ch in 0..<18 {
            for bus in matrixBuses {
                pushCellGain(channel: ch, bus: bus)
            }
        }

        if preset.selectedBus < UInt8(matrixBuses.count) {
            selectedBus = matrixBuses[Int(preset.selectedBus)]
        }

        saveMatrix()
    }

    func userDeletePreset(_ preset: ScarlettPreset) {
        presets.removeAll { $0.id == preset.id }
        savePresets()
    }

    /// True when another preset for the same device already uses `name`.
    /// Mirrors the name+device key `userSavePreset` overwrites by.
    func presetNameTaken(_ name: String, excluding preset: ScarlettPreset) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let pid = effectiveProductID(for: preset)
        return presets.contains {
            $0.id != preset.id && $0.name == trimmed && effectiveProductID(for: $0) == pid
        }
    }

    /// Rename a saved preset.  Returns false (and changes nothing) if the
    /// name is empty or already taken by another preset for the same device.
    @discardableResult
    func userRenamePreset(_ preset: ScarlettPreset, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !presetNameTaken(trimmed, excluding: preset),
              let idx = presets.firstIndex(where: { $0.id == preset.id }) else { return false }
        presets[idx].name = trimmed
        savePresets()
        return true
    }

    /// Build a snapshot of the current state in `ScarlettPreset` form.  The
    /// snapshot is identical in shape to what `userSavePreset` writes to
    /// the in-app list; the difference is just where it's persisted.
    func currentSnapshot(named name: String) -> ScarlettPreset {
        ScarlettPreset(
            id: UUID(),
            name: name,
            createdAt: Date(),
            schemaVersion: ScarlettPreset.currentSchemaVersion,
            productID: profile.productID,
            routes: Dictionary(uniqueKeysWithValues:
                snapshotRoutes().map { ($0.key, $0.value.rawValue) }),
            mixerSources: mixerSources.map { $0.rawValue },
            mixerLevels: mixerLevels,
            mixerPans: mixerPans,
            mixerMutes: mixerMutes,
            mixerSolos: mixerSolos,
            mixerNames: mixerNames,
            linkedLefts: Array(linkedPairs),
            selectedBus: UInt8(selectedBus.matrixIndex ?? 0)
        )
    }

    /// Export the current state to a `.scmx` file at the given URL.  The file
    /// format is JSON-encoded `ScarlettPreset` for cross-compatibility with
    /// the in-app preset list (you can save a file, then load it back as a
    /// preset and vice versa).
    func userExportSnapshot(to url: URL) throws {
        let snapshot = currentSnapshot(named: url.deletingPathExtension().lastPathComponent)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: url)
        logEvent(.info, "Export", "Exported snapshot to \(url.lastPathComponent)")
    }

    /// Import a `.scmx` (or legacy `.8i6`) snapshot file from the given URL and apply it
    /// (routes + matrix + sources) the same way `userLoadPreset` does.
    func userImportSnapshot(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let preset = try JSONDecoder().decode(ScarlettPreset.self, from: data)
        try userLoadPreset(preset)
        logEvent(.info, "Import", "Imported snapshot \(url.lastPathComponent)")
    }

    // MARK: - Reset

    /// Apply a sensible "factory" default config:
    /// - Outputs (Monitor L/R + Phones L/R) routed direct from DAW 1/DAW 2 so
    ///   Mac audio is audible immediately.  S/PDIF outputs default Off.
    /// - Matrix mixer cleared: all levels 0 dB, all pans centered, no mutes/
    ///   solos/links.
    /// - Pinned DAW return (ch 14 + 15) re-established with DAW 1/2 sources
    ///   and hard L/R pans — ready to be brought up to mix DAW back through
    ///   the matrix if the user wants to.
    /// Hardware switches (impedance / hi-lo), clock, sample rate and master
    /// output attenuation are left alone.
    func userResetRoutingAndMatrix() {
        let p = profile
        ensureRouteSlots(for: p)

        // The larger ADAT-equipped models (18i6/18i8/18i20) default their
        // Monitor + Phones through Mix M1/M2 (the matrix must be heard at the
        // physical outputs) and seed the matrix with all 8 analog + ADAT +
        // S/PDIF inputs.  The compact models (8i6/6i6) keep DAW 1/2 direct for
        // immediate Mac playback and seed 4 analog + S/PDIF.  We key off ADAT
        // rather than a specific PID so every model lands on the right preset.
        let hasADAT = p.sources.contains { $0.displayName.hasPrefix("ADAT") }
        let useMixOutputs = hasADAT

        // Only Monitor and the Phones pair(s) default to a live source. Every
        // other output (extra line pairs, S/PDIF, ADAT) defaults to Off, same
        // as it always has — keyed by `pairLabel` rather than a hardcoded
        // wValue because the 18i20's wValue 2/3 is Line 3/4; its Phones 1/2
        // are Line 7–10 (see the 18i20's profile comment).
        let monitorWValues = p.physicalOutputs.filter { $0.pairLabel == "Monitor" }.map(\.wValue)
        let phonesWValues  = p.physicalOutputs.filter { $0.pairLabel.hasPrefix("Phones") }.map(\.wValue)
        for out in p.physicalOutputs {
            let source: MixBus
            if out.isLeft, monitorWValues.contains(out.wValue) || phonesWValues.contains(out.wValue) {
                source = useMixOutputs ? .m1 : .daw1
            } else if !out.isLeft, monitorWValues.contains(out.wValue) || phonesWValues.contains(out.wValue) {
                source = useMixOutputs ? .m2 : .daw2
            } else {
                source = .off
            }
            routes[out.wValue] = source
            if let dev = device {
                writeAsync { try? dev.setRouteSource(wValue: out.wValue, from: source) }
            }
        }
        saveRoutes()

        mixerLevels = Array(repeating: Array(repeating: 0, count: stereoPairCount), count: 18)
        mixerPans   = Array(repeating: Array(repeating: 0, count: stereoPairCount), count: 18)
        mixerMutes  = Array(repeating: false, count: 18)
        mixerSolos  = Array(repeating: false, count: 18)
        linkedPairs = []

        // Seed the matrix with the device's physical inputs (analog, then
        // S/PDIF, then ADAT — in source order), skipping the two channels
        // reserved for the pinned DAW 1/2 strips so those aren't overwritten by
        // ensurePinnedDawChannels() below. Devices with more inputs than free
        // channels keep the earlier ones; unused channels stay Off.
        let physicalInputs = profile.sources.filter { $0.category == .analog || $0.category == .digital }
        let pinnedChannels: Set<Int> = hasPinnedDawReturn
            ? [Self.pinnedDawLeftChannel, Self.pinnedDawRightChannel]
            : []
        var defaultSources: [SignalSource] = Array(repeating: .off, count: 18)
        var seedIdx = 0
        for ch in 0..<18 where !pinnedChannels.contains(ch) {
            guard seedIdx < physicalInputs.count else { break }
            defaultSources[ch] = SignalSource.fromDisplayName(physicalInputs[seedIdx].displayName) ?? .off
            seedIdx += 1
        }
        for ch in 0..<18 {
            mixerSources[ch] = .off
            if let dev = device {
                writeAsync { try? dev.setMixerSource(channel: ch, source: .off) }
            }
        }
        for ch in 0..<18 where defaultSources[ch] != .off {
            let src = defaultSources[ch]
            mixerSources[ch] = src
            if let dev = device {
                writeAsync { try? dev.setMixerSource(channel: ch, source: src) }
            }
        }

        ensurePinnedDawChannels()

        for ch in 0..<18 {
            for bus in matrixBuses {
                pushCellGain(channel: ch, bus: bus)
            }
        }

        captureRoutes.removeAll(keepingCapacity: true)
        // Capture defaults are profile data rather than "first N inputs".
        // In particular, the confirmed 18i8 intentionally keeps Analog 1-4,
        // S/PDIF 1-2, and every ADAT input in its 14 capture slots.
        let captureDefaults = Array(profile.defaultCaptureSources.enumerated())
        for (ch, src) in captureDefaults {
            captureRoutes[ch] = src
            if let dev = device {
                writeAsync { try? dev.setCaptureRoute(channel: ch, from: src) }
            }
        }
        saveCaptureRoutes()

        if monitorMono {
            userSetMonitorMono(false)
        }

        saveMatrix()
        let defaultedLabel = phonesWValues.isEmpty ? "Monitor" : "Monitor + Phones"
        let routeNote = useMixOutputs ? "\(defaultedLabel) = Mix M1/M2" : "\(defaultedLabel) = DAW 1/2"
        logEvent(.info, "Reset", "Default config applied (\(routeNote))")
    }

    /// Set the channel-wide mute directly (no toggle, no link propagation).
    /// Used by callers that drive multiple channels in concert (`PinnedDawStrip`).
    func userSetMixerMute(channel: Int, muted: Bool) {
        guard (0..<18).contains(channel) else { return }
        mixerMutes[channel] = muted
        pushAllCells(forChannel: channel)
        saveMatrix()
    }

    /// Toggle the channel-wide mute, mirroring to the linked partner.
    /// Affects every bus the channel feeds — that's the standard mixer
    /// UX (M = silence this channel everywhere).
    func userToggleMixerMute(channel: Int) {
        guard (0..<18).contains(channel) else { return }
        let newValue = !mixerMutes[channel]
        mixerMutes[channel] = newValue
        pushAllCells(forChannel: channel)
        if let partner = linkedPartner(channel) {
            mixerMutes[partner] = newValue
            pushAllCells(forChannel: partner)
        }
        saveMatrix()
    }

    /// Toggle the channel-wide solo, mirroring to the linked partner.
    /// Solo affects the gain of *every* channel on *every* bus (any
    /// non-soloed channel goes silent globally), so we re-push the
    /// entire 18 × N matrix.
    func userToggleMixerSolo(channel: Int) {
        guard (0..<18).contains(channel) else { return }
        let newValue = !mixerSolos[channel]
        mixerSolos[channel] = newValue
        if let partner = linkedPartner(channel) {
            mixerSolos[partner] = newValue
        }
        // Solo affects effectiveGain for every channel.  Re-push all cells.
        for ch in 0..<18 {
            pushAllCells(forChannel: ch)
        }
        saveMatrix()
    }

    /// Helper: push gain for `channel` to every mix bus.  Used when a
    /// channel-wide field (mute / solo) changes — every bus this
    /// channel feeds needs the new effective gain.
    private func pushAllCells(forChannel channel: Int) {
        for bus in matrixBuses {
            pushCellGain(channel: channel, bus: bus)
        }
    }

    private func pushCellGain(channel: Int, bus: MixBus) {
        guard let dev = device, let busIdx = bus.matrixIndex else { return }
        let db = effectiveGain(channel: channel, busIdx: busIdx)
        writeAsync { try? dev.setMixerGain(channel: channel, bus: bus, db: db) }
    }

    /// Re-push every matrix-channel source assignment to the device.
    private func pushMatrixSourcesToDevice() {
        guard device != nil else { return }
        for ch in 0..<18 {
            userSetMixerSource(channel: ch, source: mixerSources[ch])
        }
    }

    // MARK: - Copy mix to another bus

    /// Replicate the per-channel settings from one mix bus to another:
    /// for every matrix channel, copy that channel's level/pan/mute/solo for
    /// the source pair to the destination pair (and the cell-gains for the
    /// source bus to the destination bus).  Useful for "make M3+M4 = M1+M2".
    ///
    /// `from` and `to` are the bus's stereo pair (0 = M1+M2, 1 = M3+M4,
    /// 2 = M5+M6).  This works at the *pair* granularity because levels and
    /// pans live per-pair; mute/solo are per-cell so both members of the
    /// destination pair get updated.
    func userCopyMixPair(from sourcePair: Int, to destPair: Int) {
        guard sourcePair != destPair,
              (0..<stereoPairCount).contains(sourcePair),
              (0..<stereoPairCount).contains(destPair) else { return }
        // Mute and solo are now channel-wide, so copying a pair only
        // copies the per-pair level + pan into the destination.
        for ch in 0..<18 {
            mixerLevels[ch][destPair] = mixerLevels[ch][sourcePair]
            mixerPans[ch][destPair]   = mixerPans[ch][sourcePair]
            pushBusPair(channel: ch, pair: destPair)
        }
        saveMatrix()
        let srcName = "Mix M\(sourcePair*2 + 1)+M\(sourcePair*2 + 2)"
        let dstName = "Mix M\(destPair*2 + 1)+M\(destPair*2 + 2)"
        logEvent(.info, "Copy", "Copied \(srcName) → \(dstName)")
    }

    // MARK: - Master section helpers

    func userToggleDim() {
        dimEnabled.toggle()
        guard device != nil else { return }
        let monLeft = monitorPairLeftWValue
        if dimEnabled {
            preDimMonitorAtten = pairAtten(leftWValue: monLeft)
            userSetPairAtten(leftWValue: monLeft, db: max(-128, preDimMonitorAtten - 20))
        } else {
            userSetPairAtten(leftWValue: monLeft, db: preDimMonitorAtten)
        }
    }

    // MARK: - Save

    func saveToFlash() {
        guard let dev = device else { return }
        writeAsync { try? dev.saveSettingsToHardware() }
    }
}
