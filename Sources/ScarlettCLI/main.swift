import Foundation
import ScarlettCore

// MARK: - Pretty-print helpers

func fmtDb(_ d: Double) -> String {
    d == -.infinity ? "  -inf" : String(format: "%6.1f", d)
}

func printPeaks(_ p: PeakReading) {
    // 8i6: analog inputs 1..6 (idx 0..5) + S/PDIF 1..2 (idx 8..9 in the 18i6 layout).
    // The 18i6's analog inputs 7/8 (idx 6,7) and ADAT (idx 10..17) read as zero on the 8i6.
    let analog = p.inputs[0..<6].map(fmtDb).joined(separator: " ")
    let spdif  = p.inputs[8..<10].map(fmtDb).joined(separator: " ")
    let daw    = p.daw.map(fmtDb).joined(separator: " ")
    let mix    = p.mixer.map(fmtDb).joined(separator: " ")
    print("  in 1..6:   \(analog)")
    print("  spdif L/R: \(spdif)")
    print("  daw 1..6:  \(daw)")
    print("  mix M1..8: \(mix)")
}

// MARK: - Argument parsing helpers

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    var description: String { switch self { case .usage(let s): return s } }
}

func need(_ args: [String], _ i: Int, _ what: String) throws -> String {
    guard i < args.count else { throw CLIError.usage("missing \(what)") }
    return args[i]
}

func parseDouble(_ s: String, _ what: String) throws -> Double {
    guard let v = Double(s) else { throw CLIError.usage("\(what): expected number, got '\(s)'") }
    return v
}

func parseInt(_ s: String, _ what: String) throws -> Int {
    guard let v = Int(s) else { throw CLIError.usage("\(what): expected integer, got '\(s)'") }
    return v
}

func parseSignalOut(_ s: String) throws -> SignalOut {
    switch s.lowercased() {
    case "master": return .master
    case "mon-l", "monitor-l", "monl": return .monitorLeft
    case "mon-r", "monitor-r", "monr": return .monitorRight
    case "ph-l", "phones-l", "phl":    return .phonesLeft
    case "ph-r", "phones-r", "phr":    return .phonesRight
    default: throw CLIError.usage("unknown output '\(s)' (expect master|mon-l|mon-r|ph-l|ph-r)")
    }
}

func parseRoute(_ s: String) throws -> Route {
    switch s.lowercased() {
    case "mon-l", "monitor-l": return .monitorLeft
    case "mon-r", "monitor-r": return .monitorRight
    case "ph-l",  "phones-l":  return .phonesLeft
    case "ph-r",  "phones-r":  return .phonesRight
    case "spdif-l":            return .spdifLeft
    case "spdif-r":            return .spdifRight
    default: throw CLIError.usage("unknown route '\(s)' (expect mon-l|mon-r|ph-l|ph-r|spdif-l|spdif-r)")
    }
}

func parseMixBus(_ s: String) throws -> MixBus {
    switch s.lowercased() {
    case "off":      return .off
    case "daw1":     return .daw1
    case "daw2":     return .daw2
    case "daw3":     return .daw3
    case "daw4":     return .daw4
    case "daw5":     return .daw5
    case "daw6":     return .daw6
    case "an1", "analog1": return .analog1
    case "an2", "analog2": return .analog2
    case "an3", "analog3": return .analog3
    case "an4", "analog4": return .analog4
    case "spdif1":   return .spdif1
    case "spdif2":   return .spdif2
    case "m1": return .m1
    case "m2": return .m2
    case "m3": return .m3
    case "m4": return .m4
    case "m5": return .m5
    case "m6": return .m6
    default: throw CLIError.usage("unknown source '\(s)'")
    }
}

func parseSignalSource(_ s: String) throws -> SignalSource {
    switch s.lowercased() {
    case "off":      return .off
    case "daw1":     return .daw1
    case "daw2":     return .daw2
    case "daw3":     return .daw3
    case "daw4":     return .daw4
    case "daw5":     return .daw5
    case "daw6":     return .daw6
    case "an1", "analog1": return .analog1
    case "an2", "analog2": return .analog2
    case "an3", "analog3": return .analog3
    case "an4", "analog4": return .analog4
    case "spdif1":   return .spdif1
    case "spdif2":   return .spdif2
    default: throw CLIError.usage("unknown source '\(s)'")
    }
}

func parseMixMat(_ s: String) throws -> MixBus {
    switch s.lowercased() {
    case "m1": return .m1; case "m2": return .m2; case "m3": return .m3
    case "m4": return .m4; case "m5": return .m5; case "m6": return .m6
    default: throw CLIError.usage("unknown matrix bus '\(s)' (expect m1..m6)")
    }
}

// MARK: - Commands

let usage = """
usage: scarlett-cli <command> [args]

  info
      Print device info (firmware version, serial).

  meters [--watch]
      Read input/DAW/mixer peak meters once, or poll every 50ms.

  set-impedance <1|2> <line|inst>
      Combo inputs 1 and 2 — line or instrument impedance.

  set-hilogain <3|4> <hi|lo>
      8i6 inputs 3 and 4 — hi/lo gain switch.

  set-clock <internal|spdif|adat>
      Clock source.

  set-rate <44100|48000|88200|96000>
      Sample rate. Caution: glitches active audio streams.

  set-mute <master|mon-l|mon-r|ph-l|ph-r> <on|off>
      Mute/unmute a post-routing bus.

  set-att <master|mon-l|mon-r|ph-l|ph-r> <db>
      Bus attenuation. db <= 0.

  set-route <mon-l|mon-r|ph-l|ph-r|spdif-l|spdif-r> <source>
      Wire a physical output to a source (DAWn, ANn, SPDIFn, Mn, off).

  set-mixsrc <chan 0..17> <source>
      Connect a signal to matrix-mixer input channel.

  set-mixgain <chan 0..17> <m1..m6> <db>
      Matrix-mixer per-cell gain. -128 <= db <= +6.

  monitor-hw [--watch]
      Read the hardware monitor section (18i20 knob + DIM/MUTE buttons),
      once or continuously. Shows raw bytes — press the front-panel
      buttons while watching to see which byte tracks which control.

  probe-output <wValue|all>
      SET→GET roundtrip on a physical output's attenuation + mute stage
      (stage index = route wValue + 1). Restores prior values. Use this to
      verify which outputs have a real gain stage on your device.

  save
      Persist current settings to device flash. Survives power cycle.
"""

func main() throws {
    let raw = CommandLine.arguments
    guard raw.count > 1 else {
        print(usage)
        exit(2)
    }
    let cmd = raw[1]
    let args = Array(raw.dropFirst(2))

    let dev = try ScarlettDevice()

    switch cmd {
    case "test-route":
        // SET → GET roundtrip on S/PDIF L (route index 4) — safe to wiggle
        // since nothing is connected to the S/PDIF output.
        let route = Route.spdifLeft
        func readRaw() -> String {
            let r = (try? dev.controlIn(cmd: 0x01, value: route.rawValue, index: 0x3300, length: 2)) ?? []
            return r.map { String(format: "%02x", $0) }.joined(separator: " ")
        }
        let before = readRaw()
        print("baseline:               raw=\(before)")
        for src in [MixBus.daw4, .off, .m1, .analog2, .daw1] {
            try dev.setRouteSource(route, from: src)
            usleep(20_000)
            let raw = readRaw()
            print("set → \(src.displayName.padding(toLength: 10, withPad: " ", startingAt: 0))  raw=\(raw)  expect first byte 0x\(String(format: "%02x", src.rawValue))")
        }
        print("\nConclusion: if every raw read matches 'expect', GET works. If all 00 00, GET is unsupported.")

    case "state":
        // Probe all GET_CUR reads to see what the device reports.
        func tryRead<T>(_ label: String, _ block: () throws -> T) -> String {
            do { return "\(try block())" } catch { return "ERR (\(error))" }
        }
        print("Clock source:  \(tryRead("clock") { try dev.getClockSource() })")
        print("Sample rate:   \(tryRead("rate")  { try dev.getSampleRate() }) Hz")
        print()
        print("Impedance ch1: \(tryRead("imp1") { try dev.getImpedance(channel: 0) })")
        print("Impedance ch2: \(tryRead("imp2") { try dev.getImpedance(channel: 1) })")
        print("Hi/Lo ch3:     \(tryRead("hl3")  { try dev.getHiLoGain(channel: 3) ? "Hi" : "Lo" })")
        print("Hi/Lo ch4:     \(tryRead("hl4")  { try dev.getHiLoGain(channel: 4) ? "Hi" : "Lo" })")
        print()
        for bus in [SignalOut.master, .monitorLeft, .monitorRight, .phonesLeft, .phonesRight] {
            let m = tryRead("mute") { try dev.getMute(bus) ? "MUTED" : "unmuted" }
            let a = tryRead("att")  { String(format: "%.1f dB", try dev.getAttenuation(bus)) }
            print("\(String(describing: bus).padding(toLength: 14, withPad: " ", startingAt: 0))  \(m)  att=\(a)")
        }
        print()
        for r in Route.allCases {
            let raw = (try? dev.controlIn(cmd: 0x01, value: r.rawValue, index: 0x3300, length: 2)) ?? []
            let rawHex = raw.map { String(format: "%02x", $0) }.joined(separator: " ")
            let src = tryRead("route") { try dev.getRouteSource(r) }
            print("\(r.displayName.padding(toLength: 14, withPad: " ", startingAt: 0))  ← \(src)   [raw: \(rawHex)]")
        }
        print()
        print("Matrix mixer sources (channels 0..17):")
        for ch in 0..<18 {
            let raw = (try? dev.controlIn(cmd: 0x01, value: 0x0600 + UInt16(ch), index: 0x3200, length: 2)) ?? []
            let rawHex = raw.map { String(format: "%02x", $0) }.joined(separator: " ")
            let src = tryRead("msrc") { try dev.getMixerSource(channel: ch) }
            print("  ch\(String(format: "%2d", ch))  ← \(src)   [raw: \(rawHex)]")
        }
        print()
        print("Matrix mixer gains, channel 0 → M1..M\(dev.profile.mixBusCount):")
        for bus in dev.profile.matrixOutputBuses {
            guard let idx = bus.matrixIndex else { continue }
            let mtx = UInt16(0 << 3) + UInt16(idx)
            let raw = (try? dev.controlIn(cmd: 0x01, value: 0x0100 + mtx, index: 0x3c00, length: 2)) ?? []
            let rawHex = raw.map { String(format: "%02x", $0) }.joined(separator: " ")
            let g = tryRead("mgain") { String(format: "%.1f dB", try dev.getMixerGain(channel: 0, bus: bus)) }
            print("  \(bus)  \(g)   [raw: \(rawHex)]")
        }

    case "info":
        let fw = dev.firmwareBCD().map { bcd -> String in
            let hi = (bcd >> 8) & 0xff
            let lo = bcd & 0xff
            let major = (hi >> 4) * 10 + (hi & 0xf)
            let minor = (lo >> 4) * 10 + (lo & 0xf)
            return String(format: "v%d.%02d", major, minor)
        } ?? "?"
        let sn = dev.serialNumber() ?? "?"
        print("Scarlett 8i6 1st Gen (VID 0x1235 / PID 0x8002)")
        print("  firmware: \(fw)")
        print("  serial:   \(sn)")

    case "meters":
        let watch = args.contains("--watch")
        if watch {
            print("Polling peaks every 50ms — Ctrl-C to stop.\n")
            while true {
                let p = try dev.readPeaks()
                print("\u{001B}[2J\u{001B}[H", terminator: "")  // clear + home
                printPeaks(p)
                fflush(stdout)
                usleep(50_000)
            }
        } else {
            printPeaks(try dev.readPeaks())
        }

    case "set-impedance":
        let ch = try parseInt(need(args, 0, "channel"), "channel")
        guard ch == 1 || ch == 2 else { throw CLIError.usage("channel must be 1 or 2") }
        let mode = try need(args, 1, "mode").lowercased()
        let imp: Impedance
        switch mode {
        case "line":  imp = .line
        case "inst", "instrument": imp = .instrument
        default: throw CLIError.usage("mode must be 'line' or 'inst'")
        }
        try dev.setImpedance(channel: ch - 1, mode: imp)
        print("✓ ch\(ch) impedance → \(mode)")

    case "set-hilogain":
        let ch = try parseInt(need(args, 0, "channel"), "channel")
        guard ch == 3 || ch == 4 else { throw CLIError.usage("channel must be 3 or 4") }
        let g = try need(args, 1, "hi|lo").lowercased()
        let hi: Bool
        switch g {
        case "hi": hi = true
        case "lo": hi = false
        default: throw CLIError.usage("expect 'hi' or 'lo'")
        }
        try dev.setHiLoGain(channel: ch, hi: hi)
        print("✓ ch\(ch) gain → \(g)")

    case "set-clock":
        let s = try need(args, 0, "source").lowercased()
        let src: ClockSource
        switch s {
        case "internal", "int": src = .internalClock
        case "spdif":           src = .spdif
        case "adat":            src = .adat
        default: throw CLIError.usage("expect internal|spdif|adat")
        }
        try dev.setClockSource(src)
        print("✓ clock → \(s)")

    case "set-rate":
        let hz = try parseInt(need(args, 0, "rate"), "rate")
        try dev.setSampleRate(UInt32(hz))
        print("✓ sample rate → \(hz) Hz")

    case "set-mute":
        let bus = try parseSignalOut(try need(args, 0, "bus"))
        let on = try need(args, 1, "on|off").lowercased() == "on"
        try dev.setMute(bus, muted: on)
        print("✓ \(bus) → \(on ? "muted" : "unmuted")")

    case "set-att":
        let bus = try parseSignalOut(try need(args, 0, "bus"))
        let db  = try parseDouble(try need(args, 1, "db"), "db")
        try dev.setAttenuation(bus, db: db)
        print("✓ \(bus) → \(db) dB")

    case "set-route":
        let route = try parseRoute(try need(args, 0, "route"))
        let src   = try parseMixBus(try need(args, 1, "source"))
        try dev.setRouteSource(route, from: src)
        print("✓ route \(route) ← \(src)")

    case "set-mixsrc":
        let ch  = try parseInt(try need(args, 0, "channel"), "channel")
        let src = try parseSignalSource(try need(args, 1, "source"))
        try dev.setMixerSource(channel: ch, source: src)
        print("✓ mixer ch\(ch) ← \(src)")

    case "set-mixgain":
        let ch  = try parseInt(try need(args, 0, "channel"), "channel")
        let bus = try parseMixMat(try need(args, 1, "bus"))
        let db  = try parseDouble(try need(args, 2, "db"), "db")
        try dev.setMixerGain(channel: ch, bus: bus, db: db)
        print("✓ mixer ch\(ch) → \(bus) at \(db) dB")

    case "monitor-hw":
        func readAndPrint() throws {
            let raw = try dev.controlIn(cmd: 0x03, value: 0x0004, index: 0x3c00, length: 4)
            let hex = raw.map { String(format: "%02x", $0) }.joined(separator: " ")
            let s = try dev.getHardwareMonitorControls()
            print("raw: [\(hex)]   knob: \(String(format: "%5.1f", s.potAttenuationDb)) dB   dim: \(s.dim ? "ON " : "off")   mute: \(s.mute ? "ON " : "off")")
        }
        if args.contains("--watch") {
            print("Polling hardware monitor section every 200ms — Ctrl-C to stop.")
            print("Press the front-panel DIM and MUTE buttons and turn the knob.\n")
            while true {
                try readAndPrint()
                usleep(200_000)
            }
        } else {
            try readAndPrint()
        }

    case "probe-output":
        // Verify that a physical output's post-routing gain stage responds:
        // read attenuation, write -40 dB, read back, restore. A stage that
        // exists reads back ≈ -40; a bogus stage errors or reads garbage.
        let arg = try need(args, 0, "wValue|all").lowercased()
        let targets: [PhysicalOutput]
        if arg == "all" {
            targets = dev.profile.physicalOutputs
        } else {
            guard let wv = UInt16(arg),
                  let out = dev.profile.physicalOutputs.first(where: { $0.wValue == wv }) else {
                throw CLIError.usage("wValue must be one of: " +
                    dev.profile.physicalOutputs.map { "\($0.wValue)=\($0.displayName)" }.joined(separator: " "))
            }
            targets = [out]
        }
        print("Probing output gain stages on \(dev.profile.displayName) (stage = wValue+1):\n")
        for out in targets {
            let name = out.displayName.padding(toLength: 12, withPad: " ", startingAt: 0)
            do {
                let attBefore = try dev.getOutputAttenuation(outputWValue: out.wValue)
                let muteBefore = try dev.getOutputMute(outputWValue: out.wValue)
                try dev.setOutputAttenuation(outputWValue: out.wValue, db: -40)
                usleep(30_000)
                let attProbe = try dev.getOutputAttenuation(outputWValue: out.wValue)
                try dev.setOutputMute(outputWValue: out.wValue, muted: !muteBefore)
                usleep(30_000)
                let muteProbe = try dev.getOutputMute(outputWValue: out.wValue)
                // Restore
                try dev.setOutputAttenuation(outputWValue: out.wValue, db: attBefore)
                try dev.setOutputMute(outputWValue: out.wValue, muted: muteBefore)
                let attOK  = abs(attProbe - (-40)) < 1.0
                let muteOK = muteProbe != muteBefore
                let functional = dev.profile.hasGainStage(wValue: out.wValue)
                let verdict = (attOK && muteOK)
                    ? (functional ? "✓ PASS" : "✓ stores (NOT in audio path)")
                    : "✗ FAIL"
                print("  \(name) wValue=\(String(format: "%2d", out.wValue))  " +
                      "att: \(String(format: "%6.1f", attBefore)) → \(String(format: "%6.1f", attProbe)) dB " +
                      "(\(attOK ? "ok" : "NO"))  mute toggle: \(muteOK ? "ok" : "NO")   \(verdict)")
            } catch {
                print("  \(name) wValue=\(String(format: "%2d", out.wValue))  ERROR: \(error)")
            }
        }
        print("""

        PASS = addressable, functional gain stage.
        'stores' = the stage accepts and reads back values but is not in the
        audio path (digital outputs are fixed-level — confirmed on 18i20
        hardware and matching MixControl's FFMonitor<N> sizes).
        """)

    case "save":
        try dev.saveSettingsToHardware()
        print("✓ settings persisted to device flash")

    case "-h", "--help", "help":
        print(usage)

    default:
        print("unknown command '\(cmd)'\n")
        print(usage)
        exit(2)
    }
}

do {
    try main()
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
