// 部分测试向量派生自 HeadBridge（MIT），固定提交 5e577cb4a91a515b95596fcc4b362a86ecb639a5。
// 来源：Tests/HeadBridgeTests/RPCCodecTests.swift 与 OppoProtocolTests.swift。
import Foundation
import Testing
@testable import AuralCore

struct HeadBridgeProtocolTests {
    @Test func sonyEscapingAndSplitFramesMatchUpstream() {
        let packet = SonyMDRPacket(dataType: SonyMDRPacket.commandType, sequence: 1, payload: [0x3C, 0x3D, 0x3E, 0])
        let bytes = SonyMDRFraming.encode(packet)
        let parser = SonyMDRFrameParser()
        #expect(parser.append(bytes.prefix(bytes.count / 2)).isEmpty)
        #expect(parser.append(bytes.suffix(from: bytes.count / 2)) == [packet])
    }

    @Test func sonyRejectsBadChecksumAndDetectsBothProtocolVersions() {
        let packet = SonyMDRPacket(dataType: SonyMDRPacket.commandType, sequence: 0, payload: [0x10, 0])
        var bytes = Array(SonyMDRFraming.encode(packet))
        bytes[bytes.count - 2] ^= 1
        #expect(SonyMDRFrameParser().append(Data(bytes)).isEmpty)
        #expect(SonyMDRProtocolVersion.detect(fromInitReply: [1, 0, 0x40, 0x10]) == .v1)
        #expect(SonyMDRProtocolVersion.detect(fromInitReply: [1, 0, 3, 0, 0, 0, 0, 0]) == .v2)
        #expect(SonyMDRProtocolVersion.detect(fromInitReply: [1, 0]) == nil)
    }

    @Test func sonyV2NoiseAndBatteryBytesMatchPublishedCapture() throws {
        let ambient = try #require(SonyV2NoiseCodec.decode(
            payload: [0x67, 0x17, 0x01, 0x01, 0x01, 0x01, 0x0C],
            opcode: 0x67
        ))
        #expect(ambient.mode == .ambient)
        #expect(ambient.voice == 0x01)
        #expect(ambient.level == 0x0C)
        #expect(SonyV2NoiseCodec.setPayload(mode: .noiseCancellation, current: ambient)
                == [0x68, 0x17, 0x01, 0x01, 0x00, 0x01, 0x0C])
        #expect(SonyV2NoiseCodec.setPayload(mode: .off, current: ambient)
                == [0x68, 0x17, 0x01, 0x00, 0x00, 0x01, 0x0C])
        #expect(SonyV2NoiseCodec.setPayload(mode: .ambient, current: ambient, ambientLevel: 20)
                == [0x68, 0x17, 0x01, 0x01, 0x01, 0x01, 0x14])
        #expect(SonyV2NoiseCodec.setPayload(mode: .windReduction, current: ambient) == nil)
        #expect(SonyV2NoiseCodec.decode(
            payload: [0x67, 0x17, 0x01, 0x01, 0x01, 0x00, 0x15],
            opcode: 0x67
        ) == nil)

        let battery = try #require(SonyV2BatteryCodec.decode([0x23, 0x00, 0x3C, 0x01]))
        #expect(battery.level == 60)
        #expect(battery.isCharging)
        #expect(SonyV2BatteryCodec.decode([0x23, 0x00, 0x65, 0x00]) == nil)
    }

    @Test func sonyNoiseWriteMatchesUpstreamVector() {
        let profile = SonyV1DeviceProfile(deviceName: "WH-1000XM3")
        let payload = profile.noisePayload(mode: .noiseCancellation, ambientLevel: 20,
                                           reportedNCType: 2, reportedASMType: 1, reportedASMID: 0)
        let frame = SonyMDRFraming.encode(SonyMDRPacket(dataType: SonyMDRPacket.commandType, sequence: 1, payload: payload))
        #expect(frame.hexString == "3E 0C 01 00 00 00 08 68 02 11 02 02 01 00 00 95 3C")
    }

    @Test func oppoBatteryAndNoiseFramesMatchHardwareVectorsFromUpstream() throws {
        #expect(OppoWire.encode(command: 0x0106, sequence: 0, payload: []) == Data([0xAA, 7, 0, 0, 6, 1, 0, 0, 0]))
        let profile = try #require(OppoModelProfile.profile(for: 0x06C810))
        #expect(OppoNoiseCodec.encodeSet(mode: .cancellation, profile: profile, sequence: 1)
                == Data([0xAA, 0x0A, 0, 0, 4, 4, 1, 3, 0, 1, 1, 2]))
        #expect(OppoModelProfile.profile(for: 0xFFFFFF) == nil)
        #expect(OppoNoiseCodec.encodeSet(mode: .windReduction, profile: profile, sequence: 1) == nil)
    }

    @Test func oppoSplitBatteryReplyAndNoiseReportsUseActualValues() throws {
        var parser = OppoFrameParser()
        let bytes = Data([0xAA, 0x0D, 0, 0, 6, 0x81, 0, 6, 0, 0, 2, 1, 0x46, 2, 0x46])
        let first = parser.append(bytes.prefix(7))
        #expect(first.isEmpty)
        let messages = parser.append(bytes.suffix(from: 7))
        let message = try #require(messages.first)
        let battery = try #require(OppoBatteryCodec.decode(message.payload))
        #expect(battery.lowestEarbudLevel == 70)
        #expect(battery.left == 70)
        #expect(battery.right == 70)
        #expect(battery.caseLevel == nil)
        #expect(OppoNoiseCodec.decodeReport([0, 1, 1, 8, 0]) == .off)
        #expect(OppoNoiseCodec.decodeReport([0, 1, 1, 0x10, 0]) == .cancellation)
        #expect(OppoNoiseCodec.decodeReport([0, 1, 1, 0, 1]) == .transparency)
        #expect(OppoNoiseCodec.decodeReport([0, 1, 1, 0, 8]) == nil)
    }

    @Test @MainActor func unifiedControllerDoesNotInventDeviceOrStartOnInitialization() {
        let controller = HeadphoneController()
        #expect(controller.phase == .idle)
        #expect(controller.family == nil)
        #expect(controller.state == HeadphoneReadings())
        #expect(controller.supportedNoiseModes.isEmpty)
        controller.setNoiseMode(.cancellation)
        #expect(controller.pendingNoiseMode == nil)
        #expect(controller.diagnosticLines.isEmpty)
        controller.shutdown()
    }
}
