import Foundation
import IOBluetooth

struct SennheiserReadings: Equatable {
    var battery: Int?
    var anc: Bool?
    var transparency: Bool?
    var noiseMode: NoiseMode? { SennheiserGAIAProtocol.noiseMode(anc: anc, transparency: transparency) }
}

/// ACCENTUM 串行事务：身份 → 通知注册 → 实际读数；写入后两项 GET 均匹配才确认。
/// 不共享其他型号的命令，不重发 SET，不通过通知或界面默认值冒充确认。
@MainActor
final class SennheiserClient {
    var onConnectionChange: ((SennheiserRFCOMMStatus) -> Void)?
    var onStateChange: ((SennheiserReadings) -> Void)?
    var onNoiseWriteSent: (() -> Void)?
    var onNoiseVerificationSent: (() -> Void)?
    var onNoiseConfirmed: ((NoiseMode) -> Void)?
    var onLog: ((String) -> Void)?
    private(set) var isIdentified = false
    private(set) var isReady = false
    private(set) var state = SennheiserReadings()

    private enum Purpose { case identity, subscribe, battery, anc, transparency, write, verifyANC, verifyTransparency }
    private struct Request {
        let command: UInt16
        let payload: [UInt8]
        let purpose: Purpose
        init(_ command: UInt16, _ purpose: Purpose, payload: [UInt8] = []) {
            self.command = command; self.purpose = purpose; self.payload = payload
        }
    }
    private let transport: any SennheiserControlTransport
    private let requestTimeout: Duration
    private var decoder = SennheiserGAIADecoder()
    private var queue: [Request] = []
    private var current: Request?
    private var desired: NoiseMode?
    private var verifiedANC: Bool?
    private var verifiedTransparency: Bool?
    private var timeout: Task<Void, Never>?
    private var generation = 0
    private var connected = false
    private var stopping = false

    init(transport: any SennheiserControlTransport,
         requestTimeout: Duration = .seconds(5)) {
        self.transport = transport
        self.requestTimeout = requestTimeout
        transport.onStatusChange = { [weak self] in self?.connectionChanged($0) }
        transport.onData = { [weak self] in self?.receive($0) }
    }

    func connect(address: String, outputUID: String) {
        disconnect()
        transport.connect(address: address, outputUID: outputUID)
    }

    func disconnect() {
        stopping = true
        generation &+= 1
        timeout?.cancel(); timeout = nil
        connected = false; isReady = false; isIdentified = false
        queue.removeAll(); current = nil; desired = nil
        verifiedANC = nil; verifiedTransparency = nil
        decoder.reset(); state = SennheiserReadings()
        transport.disconnect()
        stopping = false
        onConnectionChange?(.idle)
    }

    func refresh() {
        guard isReady, current == nil, queue.isEmpty, desired == nil else { return }
        queue = [.init(SennheiserGAIAProtocol.batteryGet, .battery),
                 .init(SennheiserGAIAProtocol.ancGet, .anc),
                 .init(SennheiserGAIAProtocol.transparencyGet, .transparency)]
        sendNext()
    }

    func setNoiseMode(_ mode: NoiseMode) -> Bool {
        guard isReady, current == nil, queue.isEmpty, desired == nil,
              let writes = SennheiserGAIAProtocol.noiseWrites(mode) else { return false }
        desired = mode
        verifiedANC = nil; verifiedTransparency = nil
        queue = writes.map { Request($0.0, .write, payload: [$0.1]) }
        queue.append(.init(SennheiserGAIAProtocol.ancGet, .verifyANC))
        queue.append(.init(SennheiserGAIAProtocol.transparencyGet, .verifyTransparency))
        sendNext()
        return connected
    }

    private func connectionChanged(_ status: SennheiserRFCOMMStatus) {
        guard !stopping else { return }
        switch status {
        case .connected:
            connected = true
            queue = [.init(SennheiserGAIAProtocol.modelGet, .identity)]
            sendNext()
        case .failed(let message, let retryable): fail(message, retryable: retryable)
        case .connecting: onConnectionChange?(.connecting)
        case .idle: break
        }
    }

    private func sendNext() {
        guard connected, current == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        current = request
        generation &+= 1
        let expected = generation
        onLog?(String(format: "TX SENNHEISER %04X", request.command))
        let result = transport.send(SennheiserGAIAProtocol.request(request.command, payload: request.payload))
        // send 可以同步回调失败；已取消的事务不能再次报错或重建 timeout。
        guard generation == expected, connected else { return }
        guard result == kIOReturnSuccess else { fail("森海塞尔控制命令发送失败（\(result)）"); return }
        if request.purpose == .write { onNoiseWriteSent?() }
        if request.purpose == .verifyTransparency { onNoiseVerificationSent?() }
        timeout?.cancel()
        let timeoutDuration = requestTimeout
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: timeoutDuration) } catch { return }
            guard let self, !Task.isCancelled, self.generation == expected else { return }
            self.fail("森海塞尔控制命令回读超时", retryable: true)
        }
    }

    private func receive(_ data: Data) {
        guard connected, !stopping else { return }
        do {
            for frame in try decoder.append(data) {
                guard frame.vendor == SennheiserGAIAProtocol.vendor else { continue }
                onLog?(String(format: "RX SENNHEISER %04X [%dB]", frame.command, frame.payload.count))
                if let current, frame.command == (current.command | 0x0180) {
                    throw AudioFailure("森海塞尔耳机拒绝了控制请求")
                }
                if let request = current, frame.command == (request.command | 0x0100) {
                    timeout?.cancel(); timeout = nil
                    try accept(frame.payload, for: request)
                    guard connected else { return }
                    current = nil
                    onStateChange?(state)
                    sendNext()
                } else if isIdentified {
                    // 通知只更新实际状态，绝不推进 SET 的验证事务。
                    switch frame.command {
                    case 0x0683:
                        guard let level = SennheiserGAIAProtocol.battery(frame.payload) else { throw AudioFailure("森海塞尔电量回包无效") }
                        state.battery = level
                    case 0x1A85: state.anc = try requireToggle(frame.payload)
                    case 0x1885: state.transparency = try requireToggle(frame.payload)
                    default: continue
                    }
                    onStateChange?(state)
                }
            }
        } catch { fail(error.localizedDescription) }
    }

    private func accept(_ payload: Data, for request: Request) throws {
        switch request.purpose {
        case .identity:
            guard let model = SennheiserGAIAProtocol.modelID(payload),
                  SennheiserGAIAProtocol.isAccentumWireless(model) else {
                throw AudioFailure("当前森海塞尔型号未通过 ACCENTUM Wireless 身份核验")
            }
            isIdentified = true
            queue = [UInt8(3), 12, 13].map { Request(SennheiserGAIAProtocol.registerNotification, .subscribe, payload: [$0]) }
            queue += [.init(SennheiserGAIAProtocol.batteryGet, .battery),
                      .init(SennheiserGAIAProtocol.ancGet, .anc),
                      .init(SennheiserGAIAProtocol.transparencyGet, .transparency)]
        case .subscribe, .write: break
        case .battery:
            guard let level = SennheiserGAIAProtocol.battery(payload) else { throw AudioFailure("森海塞尔电量回包无效") }
            state.battery = level
        case .anc: state.anc = try requireToggle(payload)
        case .transparency:
            state.transparency = try requireToggle(payload)
            if !isReady, state.battery != nil, state.noiseMode != nil {
                isReady = true
                onConnectionChange?(.connected)
            }
        case .verifyANC:
            let value = try requireToggle(payload)
            verifiedANC = value; state.anc = value
        case .verifyTransparency:
            let value = try requireToggle(payload)
            verifiedTransparency = value; state.transparency = value
            guard let desired, let anc = verifiedANC, let transparency = verifiedTransparency,
                  anc == (desired == .cancellation), transparency == (desired == .transparency) else {
                throw AudioFailure("森海塞尔模式回读与请求不一致")
            }
            self.desired = nil
            onNoiseConfirmed?(desired)
        }
    }

    private func requireToggle(_ payload: Data) throws -> Bool {
        guard let value = SennheiserGAIAProtocol.toggle(payload) else {
            throw AudioFailure("森海塞尔模式开关回包无效")
        }
        return value
    }

    private func fail(_ message: String, retryable: Bool = false) {
        guard !stopping else { return }
        disconnect()
        onConnectionChange?(.failed(message, retryable: retryable))
    }
}
