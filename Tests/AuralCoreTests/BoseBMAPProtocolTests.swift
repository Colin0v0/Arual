// Bose BMAP 测试向量依据 bosectl（MIT）在 wolverine/0x4082 上记录的协议事实。
// Aural 只验证自己生成的请求、分帧与状态映射，不把上游真机结果当作 Aural 已完成验收。
import Foundation
import Testing
@testable import AuralCore

struct BoseBMAPProtocolTests {
    @Test func requestFramesMatchTheVerifiedBMAPLayout() {
        #expect(BoseBMAPProtocol.queryProductIdentity() == Data([0x00, 0x03, 0x01, 0x00]))
        #expect(BoseBMAPProtocol.queryBattery() == Data([0x02, 0x02, 0x01, 0x00]))
        #expect(BoseBMAPProtocol.queryCurrentMode() == Data([0x1F, 0x03, 0x01, 0x00]))
        #expect(BoseBMAPProtocol.switchMode(index: 0) == Data([0x1F, 0x03, 0x05, 0x02, 0x00, 0x00]))
        #expect(BoseBMAPProtocol.switchMode(index: 1) == Data([0x1F, 0x03, 0x05, 0x02, 0x01, 0x00]))
    }

    @Test func decoderHandlesSplitAndCombinedFrames() throws {
        let product = Data([0x00, 0x03, 0x03, 0x03, 0x40, 0x82, 0x01])
        let battery = Data([0x02, 0x02, 0x03, 0x04, 0x50, 0xFF, 0xFF, 0x00])
        var decoder = BoseBMAPDecoder()

        #expect(try decoder.append(product.prefix(2)).isEmpty)
        let first = try decoder.append(product.dropFirst(2) + battery)
        #expect(first.count == 2)

        let productFrame = try #require(first.first)
        #expect(productFrame.functionBlock == 0)
        #expect(productFrame.function == 3)
        #expect(productFrame.operation == .status)
        #expect(BoseBMAPProtocol.parseProductID(productFrame) == 0x4082)

        let batteryFrame = try #require(first.last)
        #expect(BoseBMAPProtocol.parseBattery(batteryFrame, model: .quietComfortUltraHeadphones2) == HeadphoneBatteryReading(single: 80))
    }

    @Test func productIdentityRequiresTheExpectedStatusReply() {
        let valid = BoseBMAPFrame(functionBlock: 0, function: 3, flags: 3,
                                  payload: Data([0x40, 0x82, 0x01]))
        #expect(BoseBMAPProtocol.parseProductID(valid) == 0x4082)

        let wrongOperation = BoseBMAPFrame(functionBlock: 0, function: 3, flags: 6,
                                           payload: Data([0x40, 0x82, 0x01]))
        let wrongFunction = BoseBMAPFrame(functionBlock: 1, function: 3, flags: 3,
                                          payload: Data([0x40, 0x82, 0x01]))
        let tooShort = BoseBMAPFrame(functionBlock: 0, function: 3, flags: 3,
                                     payload: Data([0x40, 0x82]))
        #expect(BoseBMAPProtocol.parseProductID(wrongOperation) == nil)
        #expect(BoseBMAPProtocol.parseProductID(wrongFunction) == nil)
        #expect(BoseBMAPProtocol.parseProductID(tooShort) == nil)
    }

    @Test func batteryOnlyUsesTheVerifiedOverallComponent() {
        let overall = BoseBMAPFrame(
            functionBlock: 2,
            function: 2,
            flags: 3,
            payload: Data([0x50, 0xFF, 0xFF, 0x00])
        )
        #expect(BoseBMAPProtocol.parseBattery(overall, model: .quietComfortUltraHeadphones2)
                == HeadphoneBatteryReading(single: 80))

        let system = BoseBMAPFrame(
            functionBlock: 2,
            function: 2,
            flags: 3,
            payload: Data([0x3C, 0x00, 0x00, 0x04])
        )
        #expect(BoseBMAPProtocol.parseBattery(system, model: .quietComfortUltraHeadphones2) == nil)

        let invalidLevel = BoseBMAPFrame(
            functionBlock: 2,
            function: 2,
            flags: 3,
            payload: Data([0x65, 0xFF, 0xFF, 0x00])
        )
        #expect(BoseBMAPProtocol.parseBattery(invalidLevel, model: .quietComfortUltraHeadphones2) == nil)

        let malformed = BoseBMAPFrame(
            functionBlock: 2,
            function: 2,
            flags: 3,
            payload: Data([0x50, 0xFF, 0xFF])
        )
        #expect(BoseBMAPProtocol.parseBattery(malformed, model: .quietComfortUltraHeadphones2) == nil)
    }

    @Test func noiseModesOnlyExposeVerifiedQuietAndAwarePresets() {
        func modeFrame(_ index: UInt8) -> BoseBMAPFrame {
            BoseBMAPFrame(functionBlock: 0x1F, function: 0x03, flags: 0x03,
                          payload: Data([index]))
        }

        #expect(BoseBMAPProtocol.parseNoiseMode(modeFrame(0)) == .cancellation)
        #expect(BoseBMAPProtocol.parseNoiseMode(modeFrame(1)) == .transparency)
        #expect(BoseBMAPProtocol.parseNoiseMode(modeFrame(2)) == nil)
        #expect(BoseBMAPProtocol.parseNoiseMode(modeFrame(3)) == nil)
        #expect(BoseBMAPProtocol.modeIndex(for: .cancellation) == 0)
        #expect(BoseBMAPProtocol.modeIndex(for: .transparency) == 1)
        #expect(BoseBMAPProtocol.modeIndex(for: .off) == nil)
        #expect(BoseBMAPProtocol.modeIndex(for: .windReduction) == nil)
        #expect(BoseBMAPProtocol.modeIndex(for: .adaptive) == nil)
    }

    @Test func modeVerificationWaitsForADeviceResult() {
        let result = BoseBMAPFrame(functionBlock: 0x1F, function: 0x03, flags: 0x06,
                                   payload: Data([0x00]))
        let status = BoseBMAPFrame(functionBlock: 0x1F, function: 0x03, flags: 0x03,
                                   payload: Data([0x00]))
        let unrelated = BoseBMAPFrame(functionBlock: 0x02, function: 0x02, flags: 0x06,
                                      payload: Data())
        #expect(BoseBMAPProtocol.isCompletedModeSwitch(result))
        #expect(!BoseBMAPProtocol.isCompletedModeSwitch(status))
        #expect(!BoseBMAPProtocol.isCompletedModeSwitch(unrelated))
    }

    @Test func decoderKeepsHigherFlagBitsAndRejectsRequestOnlyFrames() throws {
        var decoder = BoseBMAPDecoder()
        let responseWithPort = Data([0x02, 0x02, 0xC3, 0x01, 0x50])
        let requestFrame = Data([0x02, 0x02, 0x01, 0x00])
        let frames = try decoder.append(responseWithPort)

        #expect(frames.count == 1)
        #expect(frames.first?.flags == 0xC3)
        #expect(frames.first?.operation == .status)
        #expect(BoseBMAPProtocol.parseBattery(frames[0], model: .quietComfortUltraHeadphones2) == nil)
        #expect(throws: AudioFailure.self) { try decoder.append(requestFrame) }
    }
    @Test func decoderPreservesFramesAtEveryChunkBoundary() throws {
        let stream = BoseBMAPProtocol.queryProductIdentity() // 请求字节不混进响应流。
        #expect(stream.count == 4)
        let incoming = Data([0, 3, 3, 3, 0x40, 0x82, 1,
                             2, 2, 3, 4, 80, 255, 255, 0,
                             31, 3, 3, 1, 1])
        var referenceDecoder = BoseBMAPDecoder()
        let expected = try referenceDecoder.append(incoming)
        for chunkSize in 1...incoming.count {
            var decoder = BoseBMAPDecoder()
            var frames: [BoseBMAPFrame] = []
            for offset in stride(from: 0, to: incoming.count, by: chunkSize) {
                frames += try decoder.append(incoming.subdata(
                    in: offset..<min(offset + chunkSize, incoming.count)))
            }
            #expect(frames == expected)
        }
    }

    @Test func corruptHeaderIsAnExplicitErrorNotAGuessedFrameBoundary() throws {
        var decoder = BoseBMAPDecoder()
        #expect(throws: AudioFailure.self) {
            try decoder.append(Data([0, 3, 0x0F, 3, 0x40, 0x82, 1]))
        }
        // 严格报错时清空残留，下一次明确重连不会携带旧半包。
        let frames = try decoder.append(Data([31, 3, 3, 1, 0]))
        #expect(frames.count == 1)
        #expect(BoseBMAPProtocol.parseNoiseMode(frames[0]) == .cancellation)
    }

    @Test func resetDropsPartialFramesAndBatteryAcceptsTheRealZeroAndFullLimits() throws {
        var decoder = BoseBMAPDecoder()
        #expect(try decoder.append(Data([0, 3, 3, 3, 0x40])).isEmpty)
        decoder.reset()
        let frames = try decoder.append(Data([31, 3, 3, 1, 1]))
        #expect(frames.count == 1)
        #expect(BoseBMAPProtocol.parseNoiseMode(frames[0]) == .transparency)
        for percentage: UInt8 in [0, 100] {
            let battery = BoseBMAPFrame(functionBlock: 2, function: 2, flags: 3,
                                        payload: Data([percentage, 255, 255, 0]))
            #expect(BoseBMAPProtocol.parseBattery(battery, model: .quietComfortUltraHeadphones2)?.single == Int(percentage))
        }
    }

}
