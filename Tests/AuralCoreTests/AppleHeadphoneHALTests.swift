import Testing
@testable import AuralCore

struct AppleHeadphoneHALTests {
    @Test func earPlacementRequiresKnownStatesAndDoesNotDependOnPrimarySide() {
        #expect(AppleHeadphoneHAL.wornState(primary: 1, secondary: 2) == true)
        #expect(AppleHeadphoneHAL.wornState(primary: 2, secondary: 1) == true)
        #expect(AppleHeadphoneHAL.wornState(primary: 2, secondary: 2) == false)
        #expect(AppleHeadphoneHAL.wornState(primary: 2, secondary: 3) == false)
        #expect(AppleHeadphoneHAL.wornState(primary: 3, secondary: 3) == false)
        #expect(AppleHeadphoneHAL.wornState(primary: 0, secondary: 1) == nil)
        #expect(AppleHeadphoneHAL.wornState(primary: 1, secondary: 9) == nil)
    }

    @Test func onlyConfirmedBilateralPlacementOpensModeControls() {
        #expect(AppleHeadphoneHAL.wearState(primary: 1, secondary: 1) == .bothEars)
        #expect(AppleHeadphoneHAL.wearState(primary: 1, secondary: 2) == .singleEar)
        #expect(AppleHeadphoneHAL.wearState(primary: 3, secondary: 1) == .singleEar)
        #expect(AppleHeadphoneHAL.wearState(primary: 2, secondary: 3) == .notWorn)
        #expect(AppleHeadphoneHAL.wearState(primary: 1, secondary: 0) == .unknown)
        #expect(AppleHeadphoneHAL.wearState(primary: 0, secondary: 1) == .unknown)
        #expect(AppleHeadphoneHAL.wearState(primary: 1, secondary: 9) == .unknown)
    }

    @Test func noWearDetectionMeansNoWearGateForHeadphones() {
        // AirPods Max 这类头戴式设备不公开双耳入耳位置；没有门控不等于未佩戴。
        #expect(AppleHeadphoneWearState.notApplicable.isWorn == nil)
        #expect(AppleHeadphoneWearState.notApplicable.allowsModeControl)
        #expect(AppleHeadphoneWearState.bothEars.allowsModeControl)
        #expect(!AppleHeadphoneWearState.singleEar.allowsModeControl)
        #expect(!AppleHeadphoneWearState.notWorn.allowsModeControl)
        #expect(!AppleHeadphoneWearState.unknown.allowsModeControl)
    }

    @Test func supportMaskExposesOnlyAdvertisedListeningModes() {
        // 原始线值 3 表示当前正在透传；能力位 7 同时公开降噪、透传和自适应。
        #expect(AppleHeadphoneHAL.supportedModes(mask: 0b111, currentRaw: 3)
                == [.off, .cancellation, .transparency, .adaptive])
        #expect(AppleHeadphoneHAL.supportedModes(mask: 0b101, currentRaw: 2)
                == [.off, .cancellation, .adaptive])
        #expect(AppleHeadphoneHAL.supportedModes(mask: 0, currentRaw: 3).isEmpty)
    }

    @Test func offRemainsReachableAfterSwitchingToAnotherMode() {
        // `lsms` 不声明关闭，但原始值 1 是系统的正式聆听模式。
        // 只要设备公开了聆听模式，就应保留返回 Off 的入口。
        #expect(AppleHeadphoneHAL.supportedModes(mask: 0b111, currentRaw: 1)
                == [.off, .cancellation, .transparency, .adaptive])
        #expect(AppleHeadphoneHAL.supportedModes(mask: 0b111, currentRaw: 2).contains(.off))
        #expect(AppleHeadphoneHAL.supportedModes(mask: 0, currentRaw: 1) == [.off])
    }

    @Test func adaptiveModeHasAnExplicitName() {
        #expect(NoiseMode.adaptive.title == "自适应")
        #expect(NoiseMode.adaptive.rawValue == 4)
        #expect(BowersWilkinsNoiseProfile.standard.wireValue(for: .adaptive) == nil)
        #expect(BowersWilkinsNoiseProfile.standard.mode(for: 4) == nil)
    }
}
