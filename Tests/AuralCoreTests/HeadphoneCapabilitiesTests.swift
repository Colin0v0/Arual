import Testing
@testable import AuralCore

struct HeadphoneCapabilitiesTests {
    @Test func modelCatalogUsesTheMostSpecificNameMatch() throws {
        let px7 = try #require(
            HeadphoneModelCatalog.profile(for: "Colin Px7 S3", family: .bowersWilkins)
        )
        #expect(px7.id == "bw-px7-s3")
        #expect(px7.noiseModeCount == 3)

        let px8 = try #require(
            HeadphoneModelCatalog.profile(for: "Px8", family: .bowersWilkins)
        )
        #expect(px8.id == "bw-px8")
        #expect(px8.noiseModeCount == 3)
    }

    @Test func sonyWindReductionRequiresDeviceConfirmation() throws {
        let profile = try #require(
            HeadphoneModelCatalog.profile(for: "WH-1000XM3", family: .sony)
        )
        #expect(profile.noiseModeCount == 4)
        #expect(
            profile.resolvedNoiseModes(confirmedOptionalModes: [])
                == [.off, .cancellation, .transparency]
        )
        #expect(
            profile.resolvedNoiseModes(confirmedOptionalModes: [.windReduction])
                == [.off, .cancellation, .transparency, .windReduction]
        )
    }

    @Test func oppoModelUsesTheConfirmedProductProfile() throws {
        let profile = try #require(
            HeadphoneModelCatalog.profile(for: "OPPO Enco Air5s", family: .oppo)
        )
        #expect(profile.id == "oppo-enco-air5s")
        #expect(profile.battery == .earbudsWithCase)
        #expect(profile.noiseModes == [.off, .cancellation, .transparency])
    }

    @Test func boseUltraHeadphonesUseOnlyTheVerifiedTwoModeProfile() throws {
        let profile = try #require(
            HeadphoneModelCatalog.profile(
                for: "Bose QuietComfort Ultra Headphones (2nd Gen)",
                family: .bose
            )
        )
        #expect(profile.id == "bose-quietcomfort-ultra-headphones-2")
        #expect(profile.battery == .single)
        #expect(profile.noiseModes == [.cancellation, .transparency])
        #expect(profile.compatibility == .upstreamVerified)

        let renamed = try #require(
            HeadphoneModelCatalog.profile(
                for: "Colin QC Ultra Headphones",
                family: .bose
            )
        )
        #expect(renamed.id == profile.id)
    }

    @Test func boseProductProfilesMatchTheWireBatteryShapes() throws {
        for model in BoseBMAPModel.allCases {
            let profile = try #require(HeadphoneModelCatalog.profiles.first { $0.id == model.catalogID })
            #expect(profile.family == .bose)
            #expect(profile.battery == model.batteryCapability)
            #expect(profile.noiseModes == model.noiseModes)
            #expect(profile.compatibility == model.compatibility)
        }
        let earbuds = try #require(HeadphoneModelCatalog.profile(
            for: "Bose QC Ultra Earbuds (2nd Gen)", family: .bose))
        #expect(earbuds.id == "bose-quietcomfort-ultra-earbuds-2")
        #expect(earbuds.battery == .earbudsWithCase)
    }

    @Test func sennheiserProfileIsLimitedToAccentumWireless() throws {
        let profile = try #require(
            HeadphoneModelCatalog.profile(
                for: "Sennheiser ACCENTUM Wireless",
                family: .sennheiser
            )
        )
        #expect(profile.id == "sennheiser-accentum-wireless")
        #expect(profile.battery == .single)
        #expect(profile.noiseModes == [.off, .cancellation, .transparency])
        #expect(profile.compatibility == .upstreamVerified)
        #expect(HeadphoneModelCatalog.profile(for: "Sennheiser ACCENTUM Plus",
                                              family: .sennheiser) == nil)
    }

    @Test func sonyV2ModelsUseTheirConfirmedThreeModeProfiles() throws {
        let xm5 = try #require(
            HeadphoneModelCatalog.profile(for: "WH-1000XM5", family: .sony)
        )
        #expect(xm5.id == "sony-wh-1000xm5")
        #expect(xm5.battery == .single)
        #expect(xm5.noiseModes == [.off, .cancellation, .transparency])

        let ultWear = try #require(
            HeadphoneModelCatalog.profile(for: "ULT WEAR", family: .sony)
        )
        #expect(ultWear.id == "sony-ult-wear")
        #expect(ultWear.noiseModeCount == 3)
    }

    @Test func unknownOrWrongFamilyDoesNotInheritAnotherModelProfile() {
        #expect(HeadphoneModelCatalog.profile(for: "New Bluetooth Headphones", family: .sony) == nil)
        #expect(HeadphoneModelCatalog.profile(for: "WH-1000XM3", family: .bowersWilkins) == nil)
    }

    @Test func capabilitiesReportTheActuallyVisibleModeCount() {
        let capabilities = HeadphoneCapabilities(
            battery: .single,
            noise: HeadphoneNoiseCapability(
                modes: [.off, .cancellation, .transparency],
                currentMode: .cancellation
            )
        )
        #expect(capabilities.battery == .single)
        #expect(capabilities.noiseModeCount == 3)
        #expect(capabilities.noise?.currentMode == .cancellation)
    }
}
