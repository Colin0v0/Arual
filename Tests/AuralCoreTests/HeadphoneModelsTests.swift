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
        for name in [
            "Bose QuietComfort Ultra Headphones (2nd Gen)",
            "Bose QC Ultra Headphones",
            "Colin QC Ultra Headphones",
            "Bose QuietComfort Ultra Earbuds (2nd Gen)",
            "Bose QC Ultra Earbuds",
            "Bose QC45",
            "Bose QuietComfort Headphones",
        ] {
            #expect(HeadphoneFamily.recognize(name) == .bose)
        }
        for name in ["Sennheiser ACCENTUM Wireless", "ACCENTUM Wireless"] {
            #expect(HeadphoneFamily.recognize(name) == .sennheiser)
        }
        for name in ["MacBook Air", "Sony TV", "AirPods Pro", "LE_BWHP"] {
            #expect(HeadphoneFamily.recognize(name) == nil)
        }
        for name in [
            "Bose QuietComfort 35",
            "Bose SoundLink Flex",
            "Bose QuietComfort Earbuds II",
            "Sennheiser ACCENTUM Plus",
            "Sennheiser ACCENTUM True Wireless",
            "Sennheiser MOMENTUM 4",
        ] {
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

    @Test func px7S3AddressResponseIsNormalizedWithoutWeakeningTheMatch() {
        // Px7 S3 实测返回按双字符分组的短横线地址，系统输出使用完整冒号地址。
        let uid = "EC-66-D1-CE-8C-CB:output"
        #expect(HeadphonePhysicalIdentity.canonicalAddress("ec66-d1-ce8ccb") == "EC66D1CE8CCB")
        #expect(HeadphonePhysicalIdentity.matches(reported: "ec66-d1-ce8ccb", outputUID: uid))
        #expect(!HeadphonePhysicalIdentity.matches(reported: "ec66-d1-ce8ccc", outputUID: uid))
    }

    @Test func px7S3DualRadioRequiresBowersWilkinsVendorAndMatchingName() {
        // 同一副 Px7 S3 的经典音频地址与 BLE 控制地址共享 B&W OUI，但设备号不同。
        let uid = "EC-66-D1-CE-8C-CB:output"
        #expect(HeadphonePhysicalIdentity.matchesBowersWilkinsControl(
            reported: "ec66-d1-cedf67",
            outputUID: uid,
            advertisedName: "Colin Px7S3",
            outputName: "Colin Px7 S3"
        ))
        #expect(!HeadphonePhysicalIdentity.matchesBowersWilkinsControl(
            reported: "ec66-d1-cedf67",
            outputUID: uid,
            advertisedName: "Colin Px8",
            outputName: "Colin Px7 S3"
        ))
        #expect(!HeadphonePhysicalIdentity.matchesBowersWilkinsControl(
            reported: "11-22-33-44-55-66",
            outputUID: uid,
            advertisedName: "Colin Px7S3",
            outputName: "Colin Px7 S3"
        ))
    }
}
