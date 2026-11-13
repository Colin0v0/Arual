// 四字节部件布局依据 bosectl 的 edith 真机记录；不复制合并电量的后备计算。
import Foundation
import Testing
@testable import AuralCore

struct BoseEarbudBatteryTests {
    private func decode(_ payload: [UInt8]) -> HeadphoneBatteryReading? {
        BoseBMAPProtocol.parseBattery(
            BoseBMAPFrame(functionBlock: 2, function: 2, flags: 3, payload: Data(payload)),
            model: .quietComfortUltraEarbuds2)
    }

    @Test func upstreamEdithCaptureUsesComponentIDsNotPositions() {
        // 上游 fixtures/packets/qc-ultra2-earbuds/battery-status.hex。
        #expect(decode([60, 255, 255, 1, 60, 255, 255, 2, 60, 255, 255, 4, 80, 255, 255, 3])
                == HeadphoneBatteryReading(left: 60, right: 60, caseLevel: 80))
        // 调换部件顺序、保持双耳不同电量，确保没有左右耳对调或借用合并值。
        #expect(decode([65, 255, 255, 3, 82, 255, 255, 2, 1, 255, 255, 4, 79, 255, 255, 1])
                == HeadphoneBatteryReading(left: 82, right: 79, caseLevel: 65))
    }

    @Test func absentPartsAndAggregateNeverInventSingleOrOtherEarValues() {
        #expect(decode([79, 255, 255, 1]) == HeadphoneBatteryReading(right: 79))
        #expect(decode([82, 255, 255, 2]) == HeadphoneBatteryReading(left: 82))
        #expect(decode([65, 255, 255, 3]) == HeadphoneBatteryReading(caseLevel: 65))
        #expect(decode([70, 255, 255, 4]) == HeadphoneBatteryReading())
        #expect(decode([255, 255, 255, 1, 82, 255, 255, 2]) == HeadphoneBatteryReading(left: 82))
    }

    @Test func zeroAndFullAreRealLevelsButChargingIsNotInferred() {
        let reading = decode([0, 255, 255, 1, 100, 255, 255, 2, 100, 255, 255, 3])
        #expect(reading == HeadphoneBatteryReading(left: 100, right: 0, caseLevel: 100))
        #expect(reading?.isCharging == nil)
    }

    @Test func duplicateTruncatedAndInvalidRecordsAreRejected() {
        #expect(decode([]) == nil)
        #expect(decode([79, 255, 255]) == nil)
        #expect(decode([79, 255, 255, 1, 82, 255, 255]) == nil)
        #expect(decode([79, 255, 255, 1, 82, 255, 255, 1]) == nil)
        #expect(decode([101, 255, 255, 2]) == nil)
        #expect(decode([254, 255, 255, 3]) == nil)
    }

    @Test func modelIdentitySelectsOneLayoutAndNeverTriesAnother() {
        let earbudFrame = BoseBMAPFrame(functionBlock: 2, function: 2, flags: 3,
                                        payload: Data([79, 255, 255, 1]))
        #expect(BoseBMAPProtocol.parseBattery(earbudFrame, model: .quietComfortUltraHeadphones2) == nil)
        // 头戴款 component 0 不会被解释成入耳款的任何部件。
        #expect(decode([80, 255, 255, 0]) == HeadphoneBatteryReading())
        let wrongOperation = BoseBMAPFrame(functionBlock: 2, function: 2, flags: 6,
                                           payload: earbudFrame.payload)
        #expect(BoseBMAPProtocol.parseBattery(wrongOperation, model: .quietComfortUltraEarbuds2) == nil)
    }
}
