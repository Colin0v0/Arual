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

    @Test func supportMaskExposesOnlyAdvertisedListeningModes() {
        // 原始线值 3 表示当前正在透传；能力位 7 同时公开降噪、透传和自适应。
        #expect(AppleHeadphoneHAL.supportedModes(mask: 0b111, currentRaw: 3)
                == [.cancellation, .transparency, .adaptive])
        #expect(AppleHeadphoneHAL.supportedModes(mask: 0b101, currentRaw: 2)
                == [.cancellation, .adaptive])
        #expect(AppleHeadphoneHAL.supportedModes(mask: 0, currentRaw: 3).isEmpty)
    }

    @Test func offRequiresPositiveCurrentStateEvidence() {
        // 能力位图不声明关闭；只有当前确实读到关闭时才允许把它展示为可选项。
        #expect(AppleHeadphoneHAL.supportedModes(mask: 0b111, currentRaw: 1)
                == [.off, .cancellation, .transparency, .adaptive])
        #expect(!AppleHeadphoneHAL.supportedModes(mask: 0b111, currentRaw: 2).contains(.off))
    }

    @Test func adaptiveModeHasAnExplicitName() {
        #expect(NoiseMode.adaptive.title == "自适应")
        #expect(NoiseMode.adaptive.rawValue == 4)
        #expect(BowersWilkinsNoiseProfile.standard.wireValue(for: .adaptive) == nil)
        #expect(BowersWilkinsNoiseProfile.standard.mode(for: 4) == nil)
    }
}
