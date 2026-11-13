import Foundation
import Testing
@testable import AuralCore

/// GAIA 协议向量依据公开协议记录独立实现，不使用厂家名称推断未接入型号。
struct SennheiserGAIAProtocolTests {
    @Test func requestsUseTheGaiaV3HeaderAndVendor() {
        #expect(SennheiserGAIAProtocol.request(SennheiserGAIAProtocol.modelGet)
                == Data([0xFF, 0x03, 0x00, 0x00, 0x04, 0x95, 0x12, 0x06]))
        #expect(SennheiserGAIAProtocol.request(SennheiserGAIAProtocol.ancSet, payload: [1])
                == Data([0xFF, 0x03, 0x00, 0x01, 0x04, 0x95, 0x1A, 0x04, 0x01]))
        #expect(SennheiserGAIAProtocol.request(SennheiserGAIAProtocol.registerNotification,
                                              payload: [13])
                == Data([0xFF, 0x03, 0x00, 0x01, 0x04, 0x95, 0x00, 0x07, 0x0D]))
    }

    @Test func decoderHandlesSplitAndCombinedFramesWithoutResynchronizing() throws {
        let model = frame(command: 0x1306, payload: Array("ACAEBT".utf8))
        let battery = frame(command: 0x0703, payload: [42])
        var decoder = SennheiserGAIADecoder()

        #expect(try decoder.append(model.prefix(3)).isEmpty)
        let frames = try decoder.append(model.dropFirst(3) + battery)
        #expect(frames.count == 2)
        #expect(frames[0].command == 0x1306)
        #expect(frames[0].payload == Data("ACAEBT".utf8))
        #expect(frames[1].command == 0x0703)
        #expect(frames[1].payload == Data([42]))
    }

    @Test func decoderRejectsCorruptHeaderInsteadOfScanningForTheNextMarker() {
        var decoder = SennheiserGAIADecoder()
        #expect(throws: AudioFailure.self) {
            try decoder.append(Data([0xFF, 0x03, 0x04, 0x01, 0x04, 0x95, 0x13, 0x06]))
        }
        // 报错时放弃当前半包，下一次重连不能把旧字节拼进新响应。
        #expect(try! decoder.append(frame(command: 0x0703, payload: [80])).count == 1)
    }

    @Test func modelIdentityIsExactAndCaseSensitive() {
        #expect(SennheiserGAIAProtocol.modelID(Data("ACAEBT\0".utf8)) == "ACAEBT")
        #expect(SennheiserGAIAProtocol.modelID(Data("ACAEBT Black\0".utf8)) == "ACAEBT Black")
        #expect(SennheiserGAIAProtocol.modelID(Data([0x41, 0x00, 0x42])) == nil)
        let wrongModel = SennheiserGAIAProtocol.modelID(Data("MOMENTUM 4\0".utf8))
        #expect(wrongModel != nil)
        #expect(wrongModel.map(SennheiserGAIAProtocol.isAccentumWireless) == false)
        #expect(SennheiserGAIAProtocol.isAccentumWireless("ACAEBT"))
        #expect(SennheiserGAIAProtocol.isAccentumWireless("ACAEBT Black"))
        #expect(!SennheiserGAIAProtocol.isAccentumWireless("ACAEBT Plus"))
        #expect(!SennheiserGAIAProtocol.isAccentumWireless("acaebt"))
    }

    @Test func batteryAndTogglePayloadsUseStrictRanges() {
        #expect(SennheiserGAIAProtocol.battery(Data([0])) == 0)
        #expect(SennheiserGAIAProtocol.battery(Data([100])) == 100)
        #expect(SennheiserGAIAProtocol.battery(Data([101])) == nil)
        #expect(SennheiserGAIAProtocol.battery(Data()) == nil)
        #expect(SennheiserGAIAProtocol.battery(Data([50, 0])) == nil)
        #expect(SennheiserGAIAProtocol.toggle(Data([0])) == false)
        #expect(SennheiserGAIAProtocol.toggle(Data([1])) == true)
        #expect(SennheiserGAIAProtocol.toggle(Data([2])) == nil)
    }

    @Test func noiseModeRequiresBothTogglesAndUsesTheirActualPriority() {
        #expect(SennheiserGAIAProtocol.noiseMode(anc: nil, transparency: false) == nil)
        #expect(SennheiserGAIAProtocol.noiseMode(anc: true, transparency: nil) == nil)
        #expect(SennheiserGAIAProtocol.noiseMode(anc: false, transparency: false) == .off)
        #expect(SennheiserGAIAProtocol.noiseMode(anc: true, transparency: false) == .cancellation)
        #expect(SennheiserGAIAProtocol.noiseMode(anc: true, transparency: true) == .transparency)
        #expect(SennheiserGAIAProtocol.noiseMode(anc: false, transparency: true) == .transparency)
    }

    @Test func modeWritesAreOrderedWithoutMappingUnsupportedModes() {
        let off = SennheiserGAIAProtocol.noiseWrites(.off)
        #expect(off?.count == 2)
        #expect(off?[0].0 == SennheiserGAIAProtocol.transparencySet && off?[0].1 == 0)
        #expect(off?[1].0 == SennheiserGAIAProtocol.ancSet && off?[1].1 == 0)

        let cancellation = SennheiserGAIAProtocol.noiseWrites(.cancellation)
        #expect(cancellation?.count == 2)
        #expect(cancellation?[0].0 == SennheiserGAIAProtocol.transparencySet && cancellation?[0].1 == 0)
        #expect(cancellation?[1].0 == SennheiserGAIAProtocol.ancSet && cancellation?[1].1 == 1)

        let transparency = SennheiserGAIAProtocol.noiseWrites(.transparency)
        #expect(transparency?.count == 2)
        #expect(transparency?[0].0 == SennheiserGAIAProtocol.ancSet && transparency?[0].1 == 0)
        #expect(transparency?[1].0 == SennheiserGAIAProtocol.transparencySet && transparency?[1].1 == 1)

        #expect(SennheiserGAIAProtocol.noiseWrites(.adaptive) == nil)
        #expect(SennheiserGAIAProtocol.noiseWrites(.windReduction) == nil)
    }

    private func frame(command: UInt16, payload: [UInt8]) -> Data {
        let length = UInt16(payload.count)
        return Data([0xFF, 0x03, UInt8(length >> 8), UInt8(length & 0xFF),
                     0x04, 0x95, UInt8(command >> 8), UInt8(command & 0xFF)] + payload)
    }
}
