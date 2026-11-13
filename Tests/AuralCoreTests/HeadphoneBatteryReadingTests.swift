import Foundation
import Testing
@testable import AuralCore

struct HeadphoneBatteryReadingTests {
    @Test func menuBarSourceUsesStableUIDStorage() {
        let values: [MenuBarBatterySource] = [
            .off,
            .currentOutput,
            .pinned(deviceUID: "Bluetooth:AA-BB-CC-DD-EE-01")
        ]
        for value in values {
            #expect(MenuBarBatterySource(storageValue: value.storageValue) == value)
        }
        #expect(MenuBarBatterySource(storageValue: "pinned:") == nil)
        #expect(MenuBarBatterySource(storageValue: "unknown") == nil)
    }

    @Test func currentOutputDirectlyMapsToItsOwnHeadphone() {
        let candidate = MenuBarBatteryCandidate(
            deviceUID: "headphone",
            displayName: "Headphone",
            reading: HeadphoneBatteryReading(single: 82)
        )
        let other = MenuBarBatteryCandidate(
            deviceUID: "other",
            displayName: "Other",
            reading: HeadphoneBatteryReading(single: 45)
        )
        let result = MenuBarBatteryResolver.resolve(
            source: .currentOutput,
            currentOutput: .direct(deviceUID: "headphone"),
            candidates: [other, candidate]
        )
        #expect(result == candidate)
    }

    @Test func multiOutputShowsOnlyAnUnambiguousControlledHeadphone() {
        let headphone = MenuBarBatteryCandidate(
            deviceUID: "headphone",
            displayName: "Headphone",
            reading: HeadphoneBatteryReading(single: 82)
        )
        let onlyHeadphone = MenuBarBatteryResolver.resolve(
            source: .currentOutput,
            currentOutput: .multiOutput(memberUIDs: ["speaker", "headphone"]),
            candidates: [headphone]
        )
        #expect(onlyHeadphone == headphone)

        let secondHeadphone = MenuBarBatteryCandidate(
            deviceUID: "second",
            displayName: "Second Headphone",
            reading: HeadphoneBatteryReading(single: 77)
        )
        let ambiguous = MenuBarBatteryResolver.resolve(
            source: .currentOutput,
            currentOutput: .multiOutput(memberUIDs: ["headphone", "second", "speaker"]),
            candidates: [headphone, secondHeadphone]
        )
        #expect(ambiguous == nil)
    }

    @Test func pinnedDisconnectDoesNotSelectAnotherHeadphone() {
        let pinned = MenuBarBatteryCandidate(
            deviceUID: "pinned",
            displayName: "Pinned",
            reading: HeadphoneBatteryReading(single: 88)
        )
        let other = MenuBarBatteryCandidate(
            deviceUID: "other",
            displayName: "Other",
            reading: HeadphoneBatteryReading(single: 45)
        )
        let connected = MenuBarBatteryResolver.resolve(
            source: .pinned(deviceUID: "pinned"),
            currentOutput: .direct(deviceUID: "other"),
            candidates: [other, pinned]
        )
        #expect(connected == pinned)

        let result = MenuBarBatteryResolver.resolve(
            source: .pinned(deviceUID: "missing"),
            currentOutput: .direct(deviceUID: "other"),
            candidates: [other]
        )
        #expect(result == nil)
    }

    @Test func unsupportedCurrentOutputDoesNotBorrowAnotherHeadphone() {
        let other = MenuBarBatteryCandidate(
            deviceUID: "other",
            displayName: "Other",
            reading: HeadphoneBatteryReading(single: 45)
        )
        let result = MenuBarBatteryResolver.resolve(
            source: .currentOutput,
            currentOutput: .unsupported,
            candidates: [other]
        )
        #expect(result == nil)

        let off = MenuBarBatteryResolver.resolve(
            source: .off,
            currentOutput: .direct(deviceUID: "other"),
            candidates: [other]
        )
        #expect(off == nil)
    }

    @Test func oppoDecoderRetainsLeftRightAndCaseParts() throws {
        let payload: [UInt8] = [0x00, 0x03, 0x01, 0x52, 0x02, 0x4F, 0x03, 0x41]
        let battery = try #require(OppoBatteryCodec.decode(payload))
        #expect(battery.batteryReading == HeadphoneBatteryReading(left: 82, right: 79,
                                                                 caseLevel: 65, isCharging: false))
    }
    @Test func oppoRejectsIncompleteBatteryRecordsInsteadOfPublishingPartialData() {
        // count=2，但实际只有一个部件；不能把截断响应当成真实单耳读数。
        #expect(OppoBatteryCodec.decode([0, 2, 1, 82]) == nil)
        #expect(OppoBatteryCodec.decode([0, 1, 1, 101]) == nil)
        #expect(OppoBatteryCodec.decode([0, 2, 1, 82, 1, 79]) == nil)
    }

    @Test func oppoUnknownComponentsCannotInventAChargingState() throws {
        let battery = try #require(OppoBatteryCodec.decode([0, 2, 1, 82, 99, 0x81]))
        #expect(battery.batteryReading == HeadphoneBatteryReading(left: 82, isCharging: false))
        let charging = try #require(OppoBatteryCodec.decode([0, 2, 1, 0xD2, 2, 79]))
        #expect(charging.batteryReading == HeadphoneBatteryReading(left: 82, right: 79,
                                                                 isCharging: true))
    }

}
