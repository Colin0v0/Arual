import Foundation
import Testing
@testable import AuralCore

struct ProtocolTests {
    @Test func exactRequestVectors() throws {
        #expect(try BWRPC.request(BWRPCatalog.ancGet) == Data([4, 0x0B, 0x12, 1, 3]))
        #expect(try BWRPC.request(BWRPCatalog.ancSet, payload: .int(2)) == Data([7, 0x0B, 0x92, 2, 3, 1, 0, 2]))
    }

    @Test func syntheticBatteryReply() throws {
        // 协议格式构造的单元测试向量，不是来自用户耳机的抓包。
        let reply = try BWRPC.decode(Data([0x0C, 0x92, 0x0C, 8, 0, 0, 1, 0, 82]))
        var state = BowersWilkinsState()
        try state.apply(reply)
        #expect(state.battery == 82)
        #expect(state.noiseMode == nil)
    }

    @Test func upstreamSixByteShortResponseRegression() throws {
        // 此格式来自 HeadBridge RPCCodecTests：旧实现错误地把最后一个错误码字节当成尾随数据。
        let success = try BWRPC.decode(Data([0x0C, 0x12, 2, 3, 0, 0]))
        #expect(success.succeeded)
        #expect(success.payload == nil)
        let rejected = try BWRPC.decode(Data([0x0C, 0x12, 0x17, 4, 8, 0]))
        #expect(rejected.errorCode == 8)
        let wideError = try BWRPC.decode(Data([0x0C, 0x12, 2, 3, 1, 1]))
        #expect(wideError.errorCode == 257)
    }

    @Test func notificationAndError() throws {
        var state = BowersWilkinsState()
        try state.apply(BWRPC.decode(Data([0x0D, 0x92, 1, 3, 1, 0, 2])))
        #expect(state.noiseMode == .transparency)
        #expect(throws: (any Error).self) { try state.apply(BWRPC.decode(Data([0x0C, 0x12, 1, 3, 6]))) }
        #expect(state.noiseMode == .transparency)
    }

    @Test func invalidFramesAreRejected() {
        for bytes: [UInt8] in [[], [0x0C, 0x92, 1, 3], [0x0C, 0x92, 1, 3, 0, 0, 2, 0, 1],
                               [0x0C, 0x12, 1, 3, 0, 0, 0], [0x0C, 0x92, 1, 3, 0, 0, 1, 0, 1, 2]] {
            #expect(throws: (any Error).self) { try BWRPC.decode(Data(bytes)) }
        }
        #expect(throws: (any Error).self) { try BWRPC.request(BWRPCatalog.ancSet, payload: .string(String(repeating: "x", count: 260))) }
    }

    @Test func noInventedState() throws {
        let state = BowersWilkinsState()
        #expect(state.battery == nil && state.noiseMode == nil)

    }

    @Test func messagePackRoundTrip() throws {
        let value: MessagePackValue = .map(["negative": .int(-60), "bands": .array([.double(-1.5), .bool(true)]), "name": .string("宝华")])
        #expect(try MessagePack.decode(MessagePack.encode(value)) == value)
        for value in [Double.nan, .infinity, -.infinity, 1.5] {
            #expect(MessagePackValue.double(value).intValue == nil)
        }
        #expect(throws: (any Error).self) { try MessagePack.decode(Data([0x01, 0x02])) }
        #expect(throws: (any Error).self) { try MessagePack.decode(Data([0xDB, 0, 0, 1, 0])) }
        #expect(throws: (any Error).self) { try MessagePack.decode(Data([0xDD, 0, 1, 0, 0])) }
    }
}

struct ControllerInitialStateTests {
    @Test @MainActor func initializationDoesNotCreateOrInventConnection() async {
        let controller = BowersWilkinsController()
        #expect(controller.phase == .idle)
        #expect(controller.state.battery == nil)
        #expect(controller.state.noiseMode == nil)
        #expect(controller.boundOutputUID == nil)
        controller.setNoiseMode(.cancellation)
        #expect(controller.pendingNoiseMode == nil)
        #expect(!controller.busy)
        #expect(controller.diagnosticLines.isEmpty)
    }
}
