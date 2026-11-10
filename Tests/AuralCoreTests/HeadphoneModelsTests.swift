import Foundation
import Testing
@testable import AuralCore

struct HeadphoneModelsTests {
    @Test func headBridgeFamiliesAreNotLimitedToPx7S3() {
        for name in ["Colin Px7 S3", "Px7 S2", "Px8", "Pi5", "Pi6", "Pi7 S2", "Pi8"] {
            #expect(HeadphoneFamily.recognize(name) == .bowersWilkins)
        }
        for name in ["WH-1000XM3", "WF-1000XM4", "WI-C600N", "MDR-1000X", "Sony LinkBuds"] {
            #expect(HeadphoneFamily.recognize(name) == .sony)
        }
        #expect(HeadphoneFamily.recognize("OPPO Enco Air5s") == .oppo)
        for name in ["MacBook Air", "Sony TV", "AirPods Pro", "LE_BWHP"] {
            #expect(HeadphoneFamily.recognize(name) == nil)
        }
        #expect(HeadphoneFamily.isBowersWilkinsAdvertisement("LE_BWHP"))
    }

    @Test func originalPx8AndPx7S3UseDifferentWireValues() {
        let original = BowersWilkinsNoiseProfile.identify(outputName: "Colin Px8", advertisedName: "LE_BWHP")
        #expect(original == .originalPx8)
        for mode in [NoiseMode.off, .cancellation, .transparency] {
            #expect(BowersWilkinsNoiseProfile.standard.wireValue(for: mode) == mode.rawValue)
            #expect(original.wireValue(for: mode) == mode.rawValue + 1)
            #expect(original.mode(for: mode.rawValue + 1) == mode)
        }
        #expect(original.mode(for: 0) == nil)
        #expect(BowersWilkinsNoiseProfile.standard.mode(for: 3) == nil)
        #expect(BowersWilkinsNoiseProfile.unverified.wireValue(for: .cancellation) == nil)
        #expect(BowersWilkinsNoiseProfile.identify(outputName: "Pi8", advertisedName: "LE_BWHP") == .unverified)
    }

    @Test func changingBleUUIDDoesNotChangePhysicalAddress() {
        let uid = "11-22-33-44-55-66:output"
        #expect(HeadphonePhysicalIdentity.matches(reported: "11:22:33:44:55:66", outputUID: uid))
        #expect(!HeadphonePhysicalIdentity.matches(reported: "11:22:33:44:55:67", outputUID: uid))
        #expect(HeadphonePhysicalIdentity.canonicalAddress("garbage") == nil)
        #expect(HeadphonePhysicalIdentity.addressInOutputUID("BuiltInSpeakerDevice") == nil)
    }
}
