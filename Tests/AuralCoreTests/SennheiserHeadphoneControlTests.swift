import CoreAudio
import Foundation
import Testing
@testable import AuralCore

/// 通过可控传输驱动真实控制器，覆盖身份核验、回读确认和生命周期分支。
@MainActor
struct SennheiserHeadphoneControlTests {
    @Test func identityAndReadingsAreRequiredBeforeTheControllerBecomesReady() {
        let fixture = SennheiserControlFixture()
        defer { fixture.controller.shutdown() }
        fixture.connect()
        #expect(fixture.transport.sent == [SennheiserGAIAProtocol.request(SennheiserGAIAProtocol.modelGet)])
        #expect(fixture.controller.phase == .connecting)
        #expect(fixture.controller.capabilities == .none)

        fixture.respond(to: SennheiserGAIAProtocol.modelGet, payload: Array("ACAEBT\0".utf8))
        #expect(fixture.transport.sent.last == SennheiserGAIAProtocol.request(
            SennheiserGAIAProtocol.registerNotification, payload: [3]))
        #expect(fixture.controller.phase == .connecting)
        #expect(fixture.controller.capabilities == .none)

        fixture.completeInitialRead(battery: 64, anc: true, transparency: false)
        #expect(fixture.controller.phase == .ready)
        #expect(fixture.controller.identityVerified)
        #expect(fixture.controller.modelProfile?.id == "sennheiser-accentum-wireless")
        #expect(fixture.controller.state.battery == HeadphoneBatteryReading(single: 64))
        #expect(fixture.controller.state.noiseMode == .cancellation)
        #expect(fixture.controller.supportedNoiseModes == [.off, .cancellation, .transparency])
        #expect(fixture.controller.capabilities.battery == .single)
    }

    @Test func wrongModelIsRejectedBeforeAnyFeatureCommand() {
        let fixture = SennheiserControlFixture()
        defer { fixture.controller.shutdown() }
        fixture.connect()
        fixture.respond(to: SennheiserGAIAProtocol.modelGet, payload: Array("MOMENTUM 4\0".utf8))
        #expect(fixture.controller.errorMessage?.contains("ACCENTUM Wireless") == true)
        #expect(!fixture.controller.identityVerified)
        #expect(fixture.controller.capabilities == .none)
        #expect(fixture.transport.sent == [SennheiserGAIAProtocol.request(SennheiserGAIAProtocol.modelGet)])
    }

    @Test func noiseChangeWaitsForBothToggleReadbacksBeforeConfirmation() {
        let fixture = SennheiserControlFixture()
        defer { fixture.controller.shutdown() }
        fixture.ready()
        fixture.controller.setNoiseMode(.transparency)
        #expect(fixture.controller.busy)
        #expect(fixture.transport.sent.last == SennheiserGAIAProtocol.request(
            SennheiserGAIAProtocol.ancSet, payload: [0]))

        // 第一条 SET 只代表命令已发出，不能提前把白色选中块移走。
        fixture.respond(to: SennheiserGAIAProtocol.ancSet, payload: [])
        #expect(fixture.transport.sent.last == SennheiserGAIAProtocol.request(
            SennheiserGAIAProtocol.transparencySet, payload: [1]))
        #expect(fixture.controller.state.noiseMode == .cancellation)
        #expect(fixture.controller.busy)

        fixture.respond(to: SennheiserGAIAProtocol.transparencySet, payload: [])
        #expect(fixture.transport.sent.last == SennheiserGAIAProtocol.request(
            SennheiserGAIAProtocol.ancGet))
        fixture.respond(to: SennheiserGAIAProtocol.ancGet, payload: [0])
        #expect(fixture.controller.busy)
        #expect(fixture.transport.sent.last == SennheiserGAIAProtocol.request(
            SennheiserGAIAProtocol.transparencyGet))
        fixture.respond(to: SennheiserGAIAProtocol.transparencyGet, payload: [1])

        #expect(!fixture.controller.busy)
        #expect(fixture.controller.pendingNoiseMode == nil)
        #expect(fixture.controller.state.noiseMode == .transparency)
        #expect(fixture.controller.errorMessage == nil)
    }

    @Test func mismatchedReadbackFailsWithoutRetryingTheWrites() {
        let fixture = SennheiserControlFixture()
        defer { fixture.controller.shutdown() }
        fixture.ready()
        fixture.controller.setNoiseMode(.transparency)
        fixture.respond(to: SennheiserGAIAProtocol.ancSet, payload: [])
        fixture.respond(to: SennheiserGAIAProtocol.transparencySet, payload: [])
        fixture.respond(to: SennheiserGAIAProtocol.ancGet, payload: [0])
        fixture.respond(to: SennheiserGAIAProtocol.transparencyGet, payload: [0])

        #expect(fixture.controller.errorMessage?.contains("回读与请求不一致") == true)
        #expect(fixture.controller.phase != .ready)
        #expect(!fixture.controller.busy)
        #expect(fixture.transport.writes == [
            SennheiserGAIAProtocol.request(SennheiserGAIAProtocol.ancSet, payload: [0]),
            SennheiserGAIAProtocol.request(SennheiserGAIAProtocol.transparencySet, payload: [1])
        ])
    }

    @Test func notificationsUpdateActualStateButNeverAdvanceTheSetTransaction() {
        let fixture = SennheiserControlFixture()
        defer { fixture.controller.shutdown() }
        fixture.ready()
        fixture.controller.setNoiseMode(.transparency)
        fixture.transport.receive(frame(command: 0x1A85, payload: [1]))
        fixture.transport.receive(frame(command: 0x1885, payload: [1]))

        #expect(fixture.controller.busy)
        #expect(fixture.controller.pendingNoiseMode == .transparency)
        #expect(fixture.transport.sent.last == SennheiserGAIAProtocol.request(
            SennheiserGAIAProtocol.ancSet, payload: [0]))
    }

    @Test func refreshReadsBatteryAndBothTogglesInOrder() {
        let fixture = SennheiserControlFixture()
        defer { fixture.controller.shutdown() }
        fixture.ready()
        let before = fixture.transport.sent.count
        fixture.controller.refresh()
        #expect(fixture.transport.sent.count == before + 1)
        #expect(fixture.transport.sent.last == SennheiserGAIAProtocol.request(
            SennheiserGAIAProtocol.batteryGet))
        fixture.respond(to: SennheiserGAIAProtocol.batteryGet, payload: [77])
        #expect(fixture.controller.state.battery == HeadphoneBatteryReading(single: 77))
        #expect(fixture.transport.sent.last == SennheiserGAIAProtocol.request(
            SennheiserGAIAProtocol.ancGet))
        fixture.respond(to: SennheiserGAIAProtocol.ancGet, payload: [0])
        #expect(fixture.transport.sent.last == SennheiserGAIAProtocol.request(
            SennheiserGAIAProtocol.transparencyGet))
        fixture.respond(to: SennheiserGAIAProtocol.transparencyGet, payload: [1])
        #expect(fixture.controller.state.noiseMode == .transparency)
    }

    @Test func lateDataAfterDisconnectCannotRestoreState() {
        let fixture = SennheiserControlFixture()
        defer { fixture.controller.shutdown() }
        fixture.ready()
        fixture.controller.disconnect()
        let sent = fixture.transport.sent.count
        fixture.transport.receive(frame(command: 0x0683, payload: [99]))
        fixture.transport.receive(frame(command: 0x1A85, payload: [0]))
        #expect(fixture.controller.phase == .idle)
        #expect(fixture.controller.state == HeadphoneReadings())
        #expect(fixture.controller.capabilities == .none)
        #expect(fixture.transport.sent.count == sent)
    }

    @Test func sendFailureUsesTransportRetryClassificationOnlyOnce() {
        let fixture = SennheiserControlFixture()
        defer { fixture.controller.shutdown() }
        fixture.ready()
        fixture.transport.failNextSend = true
        fixture.controller.setNoiseMode(.off)
        #expect(fixture.controller.errorMessage == "测试传输中断")
        #expect(fixture.controller.isReconnecting)
        #expect(!fixture.controller.busy)
        #expect(fixture.controller.pendingNoiseMode == nil)
        #expect(fixture.controller.diagnosticLines.filter { $0.hasPrefix("ERROR") }.count == 1)
    }

    @Test func clientClassifiesAReadbackTimeoutAsRetryable() async {
        let transport = SennheiserTestTransport()
        let client = SennheiserClient(transport: transport, requestTimeout: .milliseconds(30))
        var failures: [(String, Bool)] = []
        client.onConnectionChange = { status in
            if case let .failed(message, retryable) = status { failures.append((message, retryable)) }
        }
        client.connect(address: "11:22:33:44:55:66", outputUID: "11-22-33-44-55-66:output")
        transport.onStatusChange?(.connected)
        transport.receive(frame(command: 0x1306, payload: Array("ACAEBT\0".utf8)))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(failures.count == 1)
        #expect(failures.first?.0 == "森海塞尔控制命令回读超时")
        #expect(failures.first?.1 == true)
        client.disconnect()
    }

    @Test func stoppingControlPreventsNewWrites() {
        let fixture = SennheiserControlFixture()
        defer { fixture.controller.shutdown() }
        fixture.ready()
        #expect(fixture.controller.pauseRouteAuthorization())
        let before = fixture.transport.sent.count
        fixture.controller.setNoiseMode(.transparency)
        #expect(fixture.transport.sent.count == before)
        #expect(!fixture.controller.busy)
    }

    private func frame(command: UInt16, payload: [UInt8]) -> Data {
        let length = UInt16(payload.count)
        return Data([0xFF, 0x03, UInt8(length >> 8), UInt8(length & 0xFF),
                     0x04, 0x95, UInt8(command >> 8), UInt8(command & 0xFF)] + payload)
    }
}

@MainActor
private final class SennheiserControlFixture {
    let transport = SennheiserTestTransport()
    let controller: HeadphoneController
    let output = AudioOutput(id: 81, uid: "11-22-33-44-55-66:output",
                             name: "Sennheiser ACCENTUM Wireless",
                             transport: kAudioDeviceTransportTypeBluetooth)

    init() {
        let apple = AppleHeadphoneHardware(
            isSupported: { _ in false }, validateTarget: { _ in },
            snapshot: { _ in throw AudioFailure("不允许访问 Apple HAL") },
            requestMode: { _, _ in Issue.record("不得调用其他驱动") },
            waitForReadback: { await Task.yield() })
        controller = HeadphoneController(
            appleHardware: apple,
            boseTransport: UnusedBoseControlTransport(),
            sennheiserTransport: transport,
            validateClassicTarget: { _ in }
        )
    }

    func connect() {
        controller.updateOutput(output)
        transport.onStatusChange?(.connected)
    }

    func completeInitialRead(battery: UInt8, anc: Bool, transparency: Bool) {
        for feature in [UInt8(3), 12, 13] {
            #expect(transport.sent.last == SennheiserGAIAProtocol.request(
                SennheiserGAIAProtocol.registerNotification, payload: [feature]))
            respond(to: SennheiserGAIAProtocol.registerNotification, payload: [])
        }
        respond(to: SennheiserGAIAProtocol.batteryGet, payload: [battery])
        respond(to: SennheiserGAIAProtocol.ancGet, payload: [anc ? 1 : 0])
        respond(to: SennheiserGAIAProtocol.transparencyGet, payload: [transparency ? 1 : 0])
    }

    func ready() {
        connect()
        respond(to: SennheiserGAIAProtocol.modelGet, payload: Array("ACAEBT\0".utf8))
        completeInitialRead(battery: 64, anc: true, transparency: false)
    }

    func respond(to request: UInt16, payload: [UInt8]) {
        transport.receive(frame(command: request | 0x0100, payload: payload))
    }

    private func frame(command: UInt16, payload: [UInt8]) -> Data {
        let length = UInt16(payload.count)
        return Data([0xFF, 0x03, UInt8(length >> 8), UInt8(length & 0xFF),
                     0x04, 0x95, UInt8(command >> 8), UInt8(command & 0xFF)] + payload)
    }
}

@MainActor
private final class SennheiserTestTransport: SennheiserControlTransport {
    var onStatusChange: ((SennheiserRFCOMMStatus) -> Void)?
    var onData: ((Data) -> Void)?
    var sent: [Data] = []
    var writes: [Data] = []
    var failNextSend = false

    func connect(address: String, outputUID: String) {
        onStatusChange?(.connecting)
    }
    func disconnect() { onStatusChange?(.idle) }

    func send(_ data: Data) -> IOReturn {
        sent.append(data)
        if data.count >= 8 {
            let command = UInt16(data[6]) << 8 | UInt16(data[7])
            if command == SennheiserGAIAProtocol.ancSet
                || command == SennheiserGAIAProtocol.transparencySet {
                writes.append(data)
            }
        }
        if failNextSend {
            failNextSend = false
            // 复现生产传输先同步报告失败、再返回错误码的重入顺序。
            onStatusChange?(.failed("测试传输中断", retryable: true))
            return kIOReturnNotOpen
        }
        return kIOReturnSuccess
    }

    func receive(_ data: Data) {
        onData?(data)
    }
}

/// 森海塞尔测试只驱动自己的传输；Bose 依赖仍必须存在，但不能被调用。
@MainActor
private final class UnusedBoseControlTransport: BoseControlTransport {
    var onStatusChange: ((BoseRFCOMMStatus) -> Void)?
    var onData: ((Data) -> Void)?
    func connect(address: String, outputUID: String, endpoint: BoseControlEndpoint) {
        Issue.record("测试森海塞尔时不得连接 Bose")
    }
    func disconnect() {}
    func send(_ data: Data) -> IOReturn {
        Issue.record("测试森海塞尔时不得发送 Bose 命令")
        return kIOReturnNotOpen
    }
}
