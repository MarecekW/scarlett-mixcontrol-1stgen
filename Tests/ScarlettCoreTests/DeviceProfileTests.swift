import XCTest
@testable import ScarlettCore

final class DeviceProfileTests: XCTestCase {
    func testProfileIdentifiersAndDestinationsAreUnique() {
        XCTAssertEqual(Set(DeviceProfile.all.map(\.productID)).count, DeviceProfile.all.count)

        for profile in DeviceProfile.all {
            XCTAssertEqual(
                Set(profile.sources.map(\.byte)).count,
                profile.sources.count,
                "Duplicate source byte in \(profile.displayName)"
            )
            XCTAssertEqual(
                Set(profile.physicalOutputs.map(\.wValue)).count,
                profile.physicalOutputs.count,
                "Duplicate output destination in \(profile.displayName)"
            )
        }
    }

    func testEveryAdvertisedSourceRoundTripsThroughCanonicalValue() {
        for profile in DeviceProfile.all {
            for descriptor in profile.sources {
                let bus = profile.mixBus(fromWireByte: descriptor.byte)
                XCTAssertEqual(
                    profile.supportedWireByte(for: bus),
                    descriptor.byte,
                    "MixBus round-trip failed for \(descriptor.displayName) on \(profile.displayName)"
                )

                if descriptor.category != .mixOutput {
                    let source = profile.signalSource(fromWireByte: descriptor.byte)
                    XCTAssertEqual(
                        profile.supportedWireByte(for: source),
                        descriptor.byte,
                        "SignalSource round-trip failed for \(descriptor.displayName) on \(profile.displayName)"
                    )
                }
            }
        }
    }

    func testCaptureDefaultsAreCompleteAndSupported() {
        for profile in DeviceProfile.all {
            XCTAssertEqual(
                profile.defaultCaptureSources.count,
                profile.captureChannelCount,
                "Incomplete capture defaults for \(profile.displayName)"
            )
            for source in profile.defaultCaptureSources {
                XCTAssertNotNil(
                    profile.supportedWireByte(for: source),
                    "Unsupported capture default \(source.displayName) on \(profile.displayName)"
                )
            }
        }
    }

    func testConfirmed18i8CaptureOrderIsPreserved() {
        XCTAssertEqual(DeviceProfile.scarlett18i8.defaultCaptureSources, [
            .analog1, .analog2, .analog3, .analog4,
            .spdif1, .spdif2,
            .adat1, .adat2, .adat3, .adat4, .adat5, .adat6, .adat7, .adat8,
        ])
    }

    func testExtendedDawChannelsCannotLeakOntoSmallerProfiles() {
        XCTAssertNil(DeviceProfile.scarlett8i6.supportedWireByte(for: MixBus.daw13))
        XCTAssertNil(DeviceProfile.scarlett6i6.supportedWireByte(for: MixBus.daw13))
        XCTAssertNil(DeviceProfile.scarlett18i6.supportedWireByte(for: MixBus.daw13))
        XCTAssertNil(DeviceProfile.scarlett18i8.supportedWireByte(for: MixBus.daw13))

        XCTAssertEqual(DeviceProfile.scarlett18i20.supportedWireByte(for: MixBus.daw13), 0x0c)
        XCTAssertEqual(DeviceProfile.scarlett18i20.supportedWireByte(for: MixBus.daw20), 0x13)
    }

    func testPhysicalOutputsGroupIntoAdjacentPairs() {
        // The output-strip UI faders and the per-output gain stages
        // (stage index = wValue + 1) both rely on pairs being two outputs
        // with adjacent wValues, left first.
        for profile in DeviceProfile.all {
            var order: [String] = []
            var groups: [String: [PhysicalOutput]] = [:]
            for out in profile.physicalOutputs {
                if groups[out.pairLabel] == nil { order.append(out.pairLabel) }
                groups[out.pairLabel, default: []].append(out)
            }
            for label in order {
                let outs = groups[label]!
                XCTAssertEqual(outs.count, 2,
                    "\(profile.displayName) pair \(label) must have exactly 2 outputs")
                XCTAssertTrue(outs[0].isLeft && !outs[1].isLeft,
                    "\(profile.displayName) pair \(label) must be [left, right]")
                XCTAssertEqual(outs[1].wValue, outs[0].wValue + 1,
                    "\(profile.displayName) pair \(label) wValues must be adjacent")
            }
        }
    }

    func testControlledOutputCountsMatchMixControlMonitorSizes() {
        // From MixControl 1.10.6's FFMonitor<N> template instantiations —
        // the analog outputs only; digital outs store but don't apply gain.
        XCTAssertEqual(DeviceProfile.scarlett8i6.controlledOutputCount, 4)
        XCTAssertEqual(DeviceProfile.scarlett6i6.controlledOutputCount, 4)
        XCTAssertEqual(DeviceProfile.scarlett18i6.controlledOutputCount, 4)
        XCTAssertEqual(DeviceProfile.scarlett18i8.controlledOutputCount, 6)
        XCTAssertEqual(DeviceProfile.scarlett18i20.controlledOutputCount, 10)

        for profile in DeviceProfile.all {
            XCTAssertLessThanOrEqual(
                profile.controlledOutputCount, profile.physicalOutputs.count,
                "\(profile.displayName) can't control more outputs than it has")
            // Controlled outputs must be a clean prefix of whole pairs so
            // a pair is never half-controlled.
            XCTAssertTrue(profile.controlledOutputCount.isMultiple(of: 2),
                "\(profile.displayName) controlled outputs must cover whole pairs")
        }
    }

    func testOutputStageIndexingMatchesLegacySignalOut() {
        // The generic per-output gain stage addressing (stage = wValue + 1)
        // must agree with the legacy SignalOut constants verified on the 8i6.
        XCTAssertEqual(SignalOut.monitorLeft.rawValue,  0 + 1)   // Monitor L = route 0
        XCTAssertEqual(SignalOut.monitorRight.rawValue, 1 + 1)   // Monitor R = route 1
        XCTAssertEqual(SignalOut.phonesLeft.rawValue,   2 + 1)   // Phones  L = route 2
        XCTAssertEqual(SignalOut.phonesRight.rawValue,  3 + 1)   // Phones  R = route 3
    }

    func testExisting8i6CanonicalRawValuesRemainStable() {
        XCTAssertEqual(MixBus.daw1.rawValue, 0x00)
        XCTAssertEqual(MixBus.daw12.rawValue, 0x0b)
        XCTAssertEqual(MixBus.analog1.rawValue, 0x0c)
        XCTAssertEqual(MixBus.spdif1.rawValue, 0x12)
        XCTAssertEqual(MixBus.m1.rawValue, 0x14)
        XCTAssertEqual(MixBus.m6.rawValue, 0x19)
    }

    /// The 18i20's front headphone jacks are hardwired analog taps of Line
    /// 7/8 and Line 9/10 (Focusrite's support docs, 1st/2nd/3rd gen), while
    /// its wValue 2/3 is a plain rear Line 3/4. Factory reset keys the Phones
    /// defaults off `pairLabel.hasPrefix("Phones")`, so the labels must point
    /// at the taps and never at the 8i6-style wValue 2/3.
    func test18i20PhonesLabelsPointAtTheHeadphoneTaps() {
        let outputs = DeviceProfile.scarlett18i20.physicalOutputs
        let phones = outputs.filter { $0.pairLabel.hasPrefix("Phones") }
        XCTAssertEqual(phones.map(\.wValue), [0x06, 0x07, 0x08, 0x09])
        XCTAssertTrue(phones.filter { $0.wValue <= 0x07 }.allSatisfy { $0.pairLabel == "Phones 1" })
        XCTAssertTrue(phones.filter { $0.wValue >= 0x08 }.allSatisfy { $0.pairLabel == "Phones 2" })
    }
}
