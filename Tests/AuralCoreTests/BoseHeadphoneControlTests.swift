import CoreAudio
import Foundation
import IOBluetooth
import Testing
@testable import AuralCore

/// 使用可控传输驱动真实控制器，不申请权限、不连接本机耳机，也不改变输出路由。
@MainActor
struct BoseHeadphoneControlTests {
    @Test func identityMustBeConfirmedBeforeReadingOrPublishingCapabilities() {
        let fixture = BoseControlFixture()
        let controller = fixture.controller
        defer { controller.shutdown() }
        fixture.connect()
        #expect(fixture.transport.sent == [BoseBMAPProtocol.queryProductIdentity()])
        fixture.transport.receive(block: 2, function: 2, payload: [80, 255, 255, 0])
        fixture.transport.receive(block: 31, function: 3, payload: [0])
        #expect(controller.state == HeadphoneReadings())
        #expect(controller.capabilities == .none)
        fixture.identify()
        #expect(fixture.transport.sent == [BoseBMAPProtocol.queryProductIdentity(),
                                          BoseBMAPProtocol.queryBattery(),
                                          BoseBMAPProtocol.queryCurrentMode()])
        #expect(controller.capabilities.noise == nil)
        #expect(!controller.identityVerified)
        fixture.read(battery: 80, mode: 0)
        #expect(controller.phase == .ready)
        #expect(controller.identityVerified)
        #expect(controller.state.battery == HeadphoneBatteryReading(single: 80))
        #expect(controller.supportedNoiseModes == [.cancellation, .transparency])
    }

    @Test func wrongProductCannotExposeControlsOrTriggerFurtherQueries() {
        let fixture = BoseControlFixture()
        defer { fixture.controller.shutdown() }
        fixture.connect()
        fixture.transport.receive(block: 0, function: 3, payload: [0x40, 0x0C, 1])
        #expect(fixture.controller.errorMessage != nil)
        #expect(!fixture.controller.identityVerified)
        #expect(fixture.controller.capabilities == .none)
        #expect(fixture.transport.sent == [BoseBMAPProtocol.queryProductIdentity()])
    }

    @Test func unknownModeClearsThePreviousSelectionButPreservesKnownTargets() {
        let fixture = BoseControlFixture()
        defer { fixture.controller.shutdown() }
        fixture.ready()
        fixture.transport.receive(block: 31, function: 3, payload: [2])
        #expect(fixture.controller.state.noiseMode == nil)
        #expect(fixture.controller.capabilities.noise?.currentMode == nil)
        #expect(fixture.controller.supportedNoiseModes == [.cancellation, .transparency])
        fixture.controller.setNoiseMode(.cancellation)
        #expect(fixture.controller.busy)
        #expect(fixture.transport.sent.last == BoseBMAPProtocol.switchMode(index: 0))
    }

    @Test func emptyModeReplyCannotMarkTheControllerReady() {
        let fixture = BoseControlFixture()
        defer { fixture.controller.shutdown() }
        fixture.connect()
        fixture.identify()
        fixture.transport.receive(block: 2, function: 2, payload: [80, 255, 255, 0])
        fixture.transport.receive(block: 31, function: 3, payload: [])
        #expect(fixture.controller.phase != .ready)
        #expect(fixture.controller.capabilities.noise == nil)
    }

    @Test func resultAloneAndPreResultStatusCannotConfirmTheRequestedMode() {
        let fixture = BoseControlFixture()
        defer { fixture.controller.shutdown() }
        fixture.ready()
        let before = fixture.transport.sent.count
        fixture.controller.setNoiseMode(.transparency)
        #expect(fixture.transport.sent.count == before + 1)
        fixture.transport.receive(block: 31, function: 3, payload: [1])
        #expect(fixture.controller.busy)
        fixture.transport.receive(block: 31, function: 3, operation: 6, payload: [1])
        #expect(fixture.controller.busy)
        #expect(fixture.transport.sent.last == BoseBMAPProtocol.queryCurrentMode())
        fixture.transport.receive(block: 31, function: 3, payload: [1])
        #expect(!fixture.controller.busy)
        #expect(fixture.controller.pendingNoiseMode == nil)
        #expect(fixture.controller.state.noiseMode == .transparency)
    }

    @Test func failedSendIsHandledOnceAndKeepsItsRetryClassification() {
        let fixture = BoseControlFixture()
        defer { fixture.controller.shutdown() }
        fixture.ready()
        fixture.transport.failNextSend = true
        fixture.controller.setNoiseMode(.transparency)
        #expect(fixture.controller.errorMessage == "测试传输中断")
        #expect(fixture.controller.isReconnecting)
        #expect(!fixture.controller.busy)
        #expect(fixture.controller.pendingNoiseMode == nil)
        #expect(fixture.controller.diagnosticLines.filter { $0.hasPrefix("ERROR") }.count == 1)
    }

    @Test func refreshStopsAfterItsFirstSendFails() {
        let fixture = BoseControlFixture()
        defer { fixture.controller.shutdown() }
        fixture.ready()
        fixture.transport.failNextSend = true
        let before = fixture.transport.sent.count
        fixture.controller.refresh()
        #expect(fixture.transport.sent.count == before + 1)
        #expect(fixture.controller.errorMessage == "测试传输中断")
    }

    @Test func lateDataAfterDisconnectCannotRestoreBatteryOrControls() {
        let fixture = BoseControlFixture()
        defer { fixture.controller.shutdown() }
        fixture.ready()
        fixture.controller.disconnect()
        fixture.identify()
        fixture.read(battery: 90, mode: 1)
        #expect(fixture.controller.phase == .idle)
        #expect(fixture.controller.state == HeadphoneReadings())
        #expect(fixture.controller.capabilities == .none)
    }

    @Test func routePausePreventsModeWrites() {
        let fixture = BoseControlFixture()
        defer { fixture.controller.shutdown() }
        fixture.ready()
        #expect(fixture.controller.pauseRouteAuthorization())
        let before = fixture.transport.sent.count
        fixture.controller.setNoiseMode(.transparency)
        #expect(fixture.transport.sent.count == before)
        #expect(!fixture.controller.busy)
    }
    @Test func repeatedIdentityNotificationsDoNotRestartInitialQueries() {
        let fixture = BoseControlFixture()
        defer { fixture.controller.shutdown() }
        fixture.ready()
        let before = fixture.transport.sent.count
        fixture.identify()
        fixture.identify()
        #expect(fixture.controller.phase == .ready)
        #expect(fixture.transport.sent.count == before)
    }

    @Test func quietComfortHeadphonesUsesProductIDAndAcceptsProcessingReadback() {
        let fixture = BoseControlFixture(model: .quietComfortHeadphones)
        defer { fixture.controller.shutdown() }
        fixture.ready()
        #expect(fixture.controller.phase == .ready)
        #expect(fixture.controller.modelProfile?.id == "bose-quietcomfort-headphones")
        #expect(fixture.controller.capabilities.battery == .single)

        fixture.controller.setNoiseMode(.transparency)
        #expect(fixture.transport.sent.last == BoseBMAPProtocol.switchMode(index: 1))
        fixture.transport.receive(block: 31, function: 3, operation: 7, payload: [1])
        #expect(fixture.controller.busy)
        #expect(fixture.transport.sent.last == BoseBMAPProtocol.queryCurrentMode())
        // PROCESSING 只触发 GET，不重发 SET。
        #expect(fixture.transport.sent.filter { $0 == BoseBMAPProtocol.switchMode(index: 1) }.count == 1)

        fixture.transport.receive(block: 31, function: 3, payload: [1])
        #expect(!fixture.controller.busy)
        #expect(fixture.controller.state.noiseMode == .transparency)
        #expect(fixture.controller.pendingNoiseMode == nil)
    }

    @Test func quietComfort45MustInitializeBeforeProductIdentity() {
        let fixture = BoseControlFixture(model: .quietComfort45)
        defer { fixture.controller.shutdown() }
        fixture.connect()
        #expect(fixture.transport.sent == [BoseBMAPProtocol.initializeLegacyProduct()])

        // 初始化 STATUS 之前到达的身份包不能推进事务。
        fixture.identify()
        #expect(fixture.transport.sent == [BoseBMAPProtocol.initializeLegacyProduct()])
        #expect(fixture.controller.phase == .verifying)

        fixture.transport.receive(block: 0, function: 1, payload: [])
        #expect(fixture.transport.sent.last == BoseBMAPProtocol.queryProductIdentity())
        fixture.identify()
        fixture.read(battery: 80, mode: 0)
        #expect(fixture.controller.phase == .ready)
        #expect(fixture.controller.modelProfile?.id == "bose-quietcomfort-45")
        #expect(fixture.controller.modelProfile?.compatibility == .experimental)
    }

    @Test func quietComfort45InitializationFailureDoesNotQueryAProduct() {
        let fixture = BoseControlFixture(model: .quietComfort45)
        defer { fixture.controller.shutdown() }
        fixture.connect()
        fixture.transport.onStatusChange?(.failed("QC45 初始化失败", retryable: false))
        #expect(fixture.controller.errorMessage == "QC45 初始化失败")
        #expect(!fixture.controller.identityVerified)
        #expect(fixture.controller.capabilities == .none)
        #expect(fixture.transport.sent == [BoseBMAPProtocol.initializeLegacyProduct()])
    }

    @Test func malformedModeAndProtocolErrorNeverProduceReadyState() {
        let fixture = BoseControlFixture()
        defer { fixture.controller.shutdown() }
        fixture.connect()
        fixture.identify()
        fixture.transport.receive(block: 2, function: 2, payload: [80, 255, 255, 0])
        fixture.transport.receive(block: 31, function: 3, operation: 4, payload: [5])
        #expect(fixture.controller.errorMessage != nil)
        #expect(!fixture.controller.identityVerified)
        #expect(fixture.controller.capabilities == .none)
        #expect(!fixture.controller.isReconnecting)
    }

    @Test func reconnectSameUIDWithANewHALHandleDoesNotReopenTheControlChannel() {
        let fixture = BoseControlFixture()
        defer { fixture.controller.shutdown() }
        fixture.ready()
        let replacement = AudioOutput(id: 92, uid: fixture.output.uid,
                                      name: fixture.output.name, transport: fixture.output.transport)
        let before = fixture.transport.sent.count
        fixture.controller.updateOutput(replacement)
        #expect(fixture.controller.phase == .ready)
        #expect(fixture.transport.connectCount == 1)
        #expect(fixture.transport.sent.count == before)
    }

    @Test func stoppingControlStaysSuppressedAndNewTargetNeedsItsOwnIdentity() {
        let fixture = BoseControlFixture()
        defer { fixture.controller.shutdown() }
        fixture.ready()
        fixture.controller.disconnect()
        fixture.controller.updateOutput(fixture.output)
        #expect(fixture.transport.connectCount == 1)
        #expect(fixture.controller.isControlSuppressed)
        let next = AudioOutput(id: 92, uid: "11-22-33-44-55-77:output",
                               name: fixture.output.name, transport: fixture.output.transport)
        fixture.controller.updateOutput(next)
        #expect(fixture.transport.connectCount == 2)
        #expect(!fixture.controller.identityVerified)
        #expect(fixture.controller.state == HeadphoneReadings())
        #expect(fixture.controller.capabilities == .none)
    }

    @Test func oneHeadphoneFailureDoesNotChangeTheOtherHeadphone() {
        let first = BoseControlFixture()
        let second = BoseControlFixture()
        defer { first.controller.shutdown(); second.controller.shutdown() }
        first.ready()
        second.ready()
        let secondSends = second.transport.sent.count
        first.transport.failNextSend = true
        first.controller.setNoiseMode(.transparency)
        #expect(second.controller.phase == .ready)
        #expect(second.controller.state.noiseMode == .cancellation)
        #expect(second.transport.sent.count == secondSends)
        #expect(second.controller.errorMessage == nil)
    }

    @Test func earbudsReadIndependentPartsAndUseTheirProductProfile() {
        let fixture = BoseControlFixture(model: .quietComfortUltraEarbuds2)
        defer { fixture.controller.shutdown() }
        fixture.ready()
        #expect(fixture.controller.phase == .ready)
        #expect(fixture.controller.identityVerified)
        #expect(fixture.controller.state.battery == HeadphoneBatteryReading(left: 82, right: 79, caseLevel: 65))
        #expect(fixture.controller.capabilities.battery == .earbudsWithCase)
        #expect(fixture.controller.modelProfile?.id == "bose-quietcomfort-ultra-earbuds-2")
        #expect(fixture.controller.supportedNoiseModes == [.cancellation, .transparency])
        #expect(!fixture.controller.supportedNoiseModes.contains(.off))
    }

    @Test func earbudsSwitchNoiseModeOnlyAfterResultAndReadback() {
        let fixture = BoseControlFixture(model: .quietComfortUltraEarbuds2)
        defer { fixture.controller.shutdown() }
        fixture.ready()
        fixture.controller.setNoiseMode(.transparency)
        #expect(fixture.transport.sent.last == BoseBMAPProtocol.switchMode(index: 1))
        #expect(fixture.controller.state.noiseMode == .cancellation)
        fixture.transport.receive(block: 31, function: 3, operation: 6, payload: [1])
        #expect(fixture.controller.busy)
        #expect(fixture.transport.sent.last == BoseBMAPProtocol.queryCurrentMode())
        fixture.transport.receive(block: 31, function: 3, payload: [1])
        #expect(!fixture.controller.busy)
        #expect(fixture.controller.state.noiseMode == .transparency)
    }

    @Test func missingEarbudCannotKeepItsOldBatteryAndEmptyReadingsClearAllParts() {
        let fixture = BoseControlFixture(model: .quietComfortUltraEarbuds2)
        defer { fixture.controller.shutdown() }
        fixture.ready()
        fixture.transport.receive(block: 2, function: 2, payload: [255, 255, 255, 2, 79, 255, 255, 1])
        #expect(fixture.controller.state.battery == HeadphoneBatteryReading(right: 79))
        fixture.transport.receive(block: 2, function: 2, payload: [255, 255, 255, 2, 255, 255, 255, 1])
        #expect(fixture.controller.state.battery == nil)
        #expect(fixture.controller.capabilities.battery == nil)
        // 电量暂不可读不等于控制通道断开，更不能从电量推断是否入耳。
        #expect(fixture.controller.phase == .ready)
        #expect(fixture.controller.supportedNoiseModes == [.cancellation, .transparency])
    }

    @Test func aggregateOnlyBatteryCannotConfirmInitialEarbudReadiness() {
        let fixture = BoseControlFixture(model: .quietComfortUltraEarbuds2)
        defer { fixture.controller.shutdown() }
        fixture.connect()
        fixture.identify()
        fixture.transport.receive(block: 2, function: 2, payload: [80, 255, 255, 4])
        fixture.transport.receive(block: 31, function: 3, payload: [0])
        #expect(fixture.controller.phase == .verifying)
        #expect(!fixture.controller.identityVerified)
        #expect(fixture.controller.state.battery == nil)
        fixture.transport.receive(block: 2, function: 2, payload: [0, 255, 255, 2])
        #expect(fixture.controller.phase == .ready)
        #expect(fixture.controller.state.battery == HeadphoneBatteryReading(left: 0))
    }

    @Test func liveProductIdentityCannotSwitchFromHeadphonesToEarbuds() {
        let fixture = BoseControlFixture()
        defer { fixture.controller.shutdown() }
        fixture.ready()
        fixture.transport.receive(block: 0, function: 3, payload: [0x40, 0x62, 1])
        #expect(fixture.controller.errorMessage != nil)
        #expect(!fixture.controller.identityVerified)
        #expect(fixture.controller.capabilities == .none)
        #expect(fixture.controller.state == HeadphoneReadings())
    }

    @Test func renamedEarbudsKeepTheProfileConfirmedByProductID() {
        // 候选名称故意像头戴款；连接后必须由 edith 产品 ID 纠正能力表。
        let fixture = BoseControlFixture(model: .quietComfortUltraEarbuds2)
        defer { fixture.controller.shutdown() }
        fixture.ready()
        let renamed = AudioOutput(id: fixture.output.id, uid: fixture.output.uid,
                                  name: "Colin QC Ultra Headphones", transport: fixture.output.transport)
        fixture.controller.updateOutput(renamed)
        #expect(fixture.controller.modelProfile?.id == "bose-quietcomfort-ultra-earbuds-2")
        #expect(fixture.controller.capabilities.battery == .earbudsWithCase)
        #expect(fixture.transport.connectCount == 1)
    }

}

@MainActor
private final class BoseControlFixture {
    let transport = BoseTestTransport()
    let controller: HeadphoneController
    let output: AudioOutput
    let model: BoseBMAPModel

    init(model: BoseBMAPModel = .quietComfortUltraHeadphones2) {
        self.model = model
        let name: String = switch model {
        case .quietComfortUltraHeadphones2: "Bose QC Ultra Headphones 2"
        case .quietComfortUltraEarbuds2: "Bose QC Ultra Earbuds 2"
        case .quietComfortHeadphones: "Bose QuietComfort Headphones"
        case .quietComfort45: "Bose QuietComfort 45"
        }
        output = AudioOutput(id: 91, uid: "11-22-33-44-55-66:output",
                             name: name, transport: kAudioDeviceTransportTypeBluetooth)
        let apple = AppleHeadphoneHardware(
            isSupported: { _ in false }, validateTarget: { _ in },
            snapshot: { _ in throw AudioFailure("不允许访问 Apple HAL") },
            requestMode: { _, _ in Issue.record("不得调用其他驱动") },
            waitForReadback: { await Task.yield() })
        controller = HeadphoneController(appleHardware: apple, boseTransport: transport,
                                        validateClassicTarget: { _ in })
    }

    func connect() {
        controller.updateOutput(output)
        transport.onStatusChange?(.connected)
    }
    func identify() {
        transport.receive(block: 0, function: 3,
                          payload: [UInt8(model.rawValue >> 8), UInt8(model.rawValue & 0xFF), 1])
    }
    func read(battery: UInt8, mode: UInt8) {
        transport.receive(block: 2, function: 2, payload: [battery, 255, 255, 0])
        transport.receive(block: 31, function: 3, payload: [mode])
    }
    func ready() {
        connect(); identify()
        switch model {
        case .quietComfortUltraHeadphones2, .quietComfortHeadphones, .quietComfort45: read(battery: 80, mode: 0)
        case .quietComfortUltraEarbuds2:
            transport.receive(block: 2, function: 2,
                              payload: [79, 255, 255, 1, 82, 255, 255, 2, 79, 255, 255, 4, 65, 255, 255, 3])
            transport.receive(block: 31, function: 3, payload: [0])
        }
    }
}

@MainActor
private final class BoseTestTransport: BoseControlTransport {
    var onStatusChange: ((BoseRFCOMMStatus) -> Void)?
    var onData: ((Data) -> Void)?
    var sent: [Data] = []
    var failNextSend = false
    var connectCount = 0
    func connect(address: String, outputUID: String, endpoint: BoseControlEndpoint) {
        connectCount += 1
        onStatusChange?(.connecting)
    }
    func disconnect() { onStatusChange?(.idle) }
    func send(_ data: Data) -> IOReturn {
        sent.append(data)
        if failNextSend {
            failNextSend = false
            // 复现生产传输同步报告失败后，再返回错误码的重入顺序。
            onStatusChange?(.failed("测试传输中断", retryable: true))
            return kIOReturnNotOpen
        }
        return kIOReturnSuccess
    }
    func receive(block: UInt8, function: UInt8, operation: UInt8 = 3, payload: [UInt8]) {
        onData?(Data([block, function, operation, UInt8(payload.count)] + payload))
    }
}
