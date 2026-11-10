import Combine
import Foundation

public struct HeadphoneReadings: Equatable {
    public var battery: Int?
    public var noiseMode: NoiseMode?
    public init(battery: Int? = nil, noiseMode: NoiseMode? = nil) {
        self.battery = battery
        self.noiseMode = noiseMode
    }
}

/// 统一界面状态，不把厂商协议混成一套“通用指令”。
/// B&W 走 BLE RPC；Sony MDR V1 与 OPPO Enco 分别使用上游的唯一 RFCOMM 服务。
@MainActor
public final class HeadphoneController: ObservableObject {
    @Published public private(set) var phase: HeadphonePhase = .idle
    @Published public private(set) var state = HeadphoneReadings()
    @Published public private(set) var candidates: [HeadphoneCandidate] = []
    @Published public private(set) var busy = false
    @Published public private(set) var identityVerified = false
    @Published public private(set) var pendingNoiseMode: NoiseMode?
    @Published public private(set) var supportedNoiseModes: [NoiseMode] = []
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var diagnosticLines: [String] = []
    @Published public private(set) var family: HeadphoneFamily?
    @Published public private(set) var displayName = "耳机"
    @Published public private(set) var isReconnecting = false
    public private(set) var boundOutputUID: String?

    private let bowersWilkins = BowersWilkinsController()
    private let sony = SonyV1Client()
    private let oppo = OppoRFCOMMTransport()
    private var oppoParser = OppoFrameParser()
    private var oppoProfile: OppoModelProfile?
    private var oppoProductReceived = false
    private var noiseReadback = NoiseReadbackGate()
    private var sequence: UInt8 = 1
    private var output: AudioOutput?
    private var classicPolicy = HeadphoneAutoConnection()
    private var subscriptions: Set<AnyCancellable> = []
    private var deadline: Timer?
    private var deadlineGeneration: UInt64 = 0
    private var reconnect: Timer?
    private var reconnectGeneration: UInt64 = 0
    private var appleTask: Task<Void, Never>?
    private var appleGeneration: UInt64 = 0
    private var stopping = false
    private var suspended = false
    private var shuttingDown = false

    public init() {
        // 上游 ObservableObject 在属性赋值前通知，下一轮主循环再读取整份状态。
        bowersWilkins.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            self?.copyBowersWilkinsState()
        }.store(in: &subscriptions)
        sony.onConnectionStateChange = { [weak self] in self?.sonyConnectionChanged($0) }
        sony.onStateChange = { [weak self] in self?.sonyReadingsChanged($0) }
        sony.onNoiseSetSent = { [weak self] in self?.noiseReadback.didSendWrite() }
        sony.onNoiseVerificationSent = { [weak self] in self?.noiseReadback.didSendVerification() }
        sony.onNoiseModeRead = { [weak self] mode in
            guard let self, self.family == .sony, !self.stopping else { return }
            self.confirmNoiseReadback(Self.noiseMode(from: mode))
        }
        sony.onTransportLog = { [weak self] direction, text in self?.trace("\(direction.rawValue) \(text)") }
        oppo.onStatusChange = { [weak self] in self?.oppoConnectionChanged($0) }
        oppo.onData = { [weak self] in self?.receiveOppo($0) }
    }

    public func updateOutput(_ newOutput: AudioOutput?) {
        let newFamily = newOutput.flatMap(family(for:))
        let target = newFamily == nil ? nil : newOutput
        if target?.uid != output?.uid || newFamily != family {
            stopClassic()
            cancelAppleOperation()
            bowersWilkins.updateOutput(nil)
            output = target
            family = newFamily
            displayName = target?.name ?? "耳机"
            errorMessage = nil
            diagnosticLines = []
            classicPolicy.updateOutput(target?.uid)
            phase = .idle
        }
        guard !suspended, !shuttingDown else { return }
        if family == .bowersWilkins {
            bowersWilkins.updateOutput(target)
            copyBowersWilkinsState()
        } else if family == .apple {
            refreshApple()
        } else if family != nil {
            startClassicIfNeeded()
        }
    }

    /// 只有真实蓝牙输出才进入耳机控制；Apple 设备由 HAL 属性识别，不能依赖用户可改的名称。
    private func family(for output: AudioOutput) -> HeadphoneFamily? {
        guard output.isBluetooth else { return nil }
        if let recognized = HeadphoneFamily.recognize(output.name) { return recognized }
        return AppleHeadphoneHAL.isSupported(deviceID: output.id) ? .apple : nil
    }

    /// 视图只查询能力，不改变当前连接状态。
    public func supports(_ output: AudioOutput?) -> Bool {
        guard let output else { return false }
        return family(for: output) != nil
    }

    /// HAL 聆听模式控制不持有额外连接，因此 Apple 耳机没有“断开控制通道”操作。
    public var canDisconnect: Bool { family != .apple }

    public func outputUnavailable() {
        bowersWilkins.outputUnavailable()
        classicPolicy.observe(.unavailable)
        cancelAppleOperation()
        stopClassic()
        phase = .idle
    }

    public func suspend() {
        suspended = true
        bowersWilkins.suspend()
        cancelAppleOperation()
        stopClassic()
        phase = .idle
    }

    public func resume() {
        suspended = false
        bowersWilkins.resume()
        classicPolicy.radioOrWakeRecovered()
    }

    public func shutdown() {
        shuttingDown = true
        bowersWilkins.shutdown()
        cancelAppleOperation()
        stopClassic()
    }

    public func disconnect() {
        if family == .bowersWilkins { bowersWilkins.disconnect(); copyBowersWilkinsState() }
        else if family == .apple { return }
        else { classicPolicy.suppress(); stopClassic(); phase = .idle }
    }

    public func retryAutomaticConnection(output: AudioOutput) {
        guard !suspended, !shuttingDown else { return }
        updateOutput(output)
        if family == .bowersWilkins { bowersWilkins.retryAutomaticConnection(output: output) }
        else if family == .apple { refreshApple() }
        else {
            stopClassic()
            classicPolicy.manualAttempt()
            beginClassicConnection()
        }
    }

    public func scan(output: AudioOutput) {
        guard family == .bowersWilkins else { return }
        bowersWilkins.scan(output: output)
    }

    public func connect(_ id: UUID) {
        guard family == .bowersWilkins else { return }
        bowersWilkins.connect(id)
    }

    public func refresh() {
        guard phase == .ready, !busy else { return }
        errorMessage = nil
        switch family {
        case .bowersWilkins: bowersWilkins.refresh()
        case .sony: sony.refresh()
        case .oppo: sendOppo(.battery); sendOppo(.noiseControl, [0x01, 0x01])
        case .apple: refreshApple()
        case nil: break
        }
    }

    public func setNoiseMode(_ mode: NoiseMode) {
        guard phase == .ready, !busy, supportedNoiseModes.contains(mode), state.noiseMode != mode else { return }
        if family == .bowersWilkins { bowersWilkins.setNoiseMode(mode); return }
        pendingNoiseMode = mode
        noiseReadback.begin(mode)
        busy = true
        errorMessage = nil
        switch family {
        case .sony:
            let sonyMode: SonyV1NoiseMode
            switch mode {
            case .off: sonyMode = .off
            case .cancellation: sonyMode = .noiseCancellation
            case .transparency: sonyMode = .ambient
            case .windReduction: sonyMode = .windReduction
            case .adaptive:
                failClassic("Sony MDR V1 不支持自适应降噪")
                return
            }
            sony.setNoiseMode(sonyMode)
        case .oppo:
            // 只有已知产品的上游映射才能生成写帧，不猜深度或默认模式。
            guard let oppoProfile, let frame = OppoNoiseCodec.encodeSet(mode: mode, profile: oppoProfile, sequence: takeSequence()) else {
                failClassic("该耳机没有经过确认的降噪写入映射")
                return
            }
            guard oppo.send(frame) == 0 else { failClassic("OPPO 设置发送失败"); return }
            noiseReadback.didSendWrite()
            guard sendOppo(.noiseControl, [0x01, 0x01]) else { return }
            noiseReadback.didSendVerification()
        case .apple:
            writeAppleNoiseMode(mode)
        default: return
        }
        guard phase == .ready, pendingNoiseMode != nil else { return }
        armDeadline(seconds: 8) { $0.failClassic("耳机没有确认噪声模式变更") }
    }

    private func copyBowersWilkinsState() {
        guard family == .bowersWilkins else { return }
        phase = bowersWilkins.phase
        state = HeadphoneReadings(battery: bowersWilkins.state.battery, noiseMode: bowersWilkins.state.noiseMode)
        candidates = bowersWilkins.candidates
        busy = bowersWilkins.busy
        identityVerified = bowersWilkins.identityVerified
        boundOutputUID = bowersWilkins.boundOutputUID
        errorMessage = bowersWilkins.errorMessage
        pendingNoiseMode = bowersWilkins.pendingNoiseMode
        diagnosticLines = bowersWilkins.diagnosticLines
        supportedNoiseModes = state.noiseMode == nil ? [] : [.off, .cancellation, .transparency]
        isReconnecting = bowersWilkins.isReconnecting
    }

    /// Apple 耳机每次刷新都直接读取 HAL；没有建立或维护另一条蓝牙控制连接。
    private func refreshApple() {
        guard !suspended, !shuttingDown, !busy, let output, family == .apple else { return }
        do {
            let snapshot = try AppleHeadphoneHAL.snapshot(on: output.id)
            guard self.output?.uid == output.uid, family == .apple, !stopping else { return }
            state = HeadphoneReadings(battery: nil, noiseMode: snapshot.noiseMode)
            supportedNoiseModes = snapshot.supportedNoiseModes
            boundOutputUID = output.uid
            identityVerified = true
            errorMessage = nil
            phase = .ready
            trace("APPLE HAL MODE \(snapshot.noiseMode.rawValue)")
        } catch {
            failApple(error.localizedDescription)
        }
    }

    private func writeAppleNoiseMode(_ mode: NoiseMode) {
        guard let output, family == .apple else {
            failApple("当前没有可控制的 Apple 耳机")
            return
        }
        let generation = appleGeneration
        let deviceID = output.id
        let outputUID = output.uid
        appleTask?.cancel()
        appleTask = Task { [weak self] in
            let operation = Task.detached(priority: .userInitiated) {
                try AppleHeadphoneHAL.setNoiseMode(mode, on: deviceID)
            }
            do {
                let snapshot = try await operation.value
                guard let self, !Task.isCancelled, self.appleGeneration == generation,
                      self.output?.uid == outputUID, self.family == .apple else { return }
                self.cancelDeadline()
                self.state = HeadphoneReadings(battery: nil, noiseMode: snapshot.noiseMode)
                self.supportedNoiseModes = snapshot.supportedNoiseModes
                self.pendingNoiseMode = nil
                self.noiseReadback.clear()
                self.busy = false
                self.errorMessage = nil
                self.phase = .ready
                self.appleTask = nil
                self.trace("APPLE HAL SET \(mode.rawValue)")
            } catch {
                guard let self, !Task.isCancelled, self.appleGeneration == generation,
                      self.output?.uid == outputUID, self.family == .apple else { return }
                self.failApple(error.localizedDescription)
            }
        }
    }

    private func failApple(_ message: String) {
        cancelAppleOperation()
        state = HeadphoneReadings()
        supportedNoiseModes = []
        boundOutputUID = nil
        identityVerified = false
        errorMessage = message
        phase = .failed(message)
    }

    private func cancelAppleOperation() {
        appleGeneration &+= 1
        appleTask?.cancel()
        appleTask = nil
        pendingNoiseMode = nil
        noiseReadback.clear()
        busy = false
    }

    private func startClassicIfNeeded() {
        guard reconnect == nil, classicPolicy.takeInitialAttempt() else { return }
        beginClassicConnection()
    }

    private func beginClassicConnection() {
        guard !suspended, !shuttingDown, let output, family == .sony || family == .oppo else { return }
        do {
            try HeadphoneRouteGuard.check(output.uid)
            guard let address = HeadphonePhysicalIdentity.addressInOutputUID(output.uid) else {
                throw AudioFailure("系统输出没有可验证的蓝牙硬件地址")
            }
            // Core Audio 的经典蓝牙地址直接指定传输目标，不再根据相似名字列出候选。
            let bytes = stride(from: 0, to: 12, by: 2).map { index -> String in
                let start = address.index(address.startIndex, offsetBy: index)
                return String(address[start..<address.index(start, offsetBy: 2)])
            }
            boundOutputUID = output.uid
            errorMessage = nil
            phase = .connecting
            state = HeadphoneReadings()
            supportedNoiseModes = []
            trace("CONNECT \(family!.rawValue) FROM CORE AUDIO ADDRESS")
            if family == .sony { sony.connect(address: bytes.joined(separator: ":"), deviceName: output.name, outputUID: output.uid) }
            else { oppo.connect(address: bytes.joined(separator: ":"), outputUID: output.uid) }
        } catch { failClassic(error.localizedDescription) }
    }

    private func stopClassic() {
        stopping = true
        cancelDeadline()
        cancelReconnect()
        sony.disconnect()
        oppo.disconnect()
        oppoParser.reset()
        oppoProfile = nil
        oppoProductReceived = false
        sequence = 1
        state = HeadphoneReadings()
        candidates = []
        supportedNoiseModes = []
        boundOutputUID = nil
        identityVerified = false
        pendingNoiseMode = nil
        noiseReadback.clear()
        busy = false
        stopping = false
    }

    private func failClassic(_ message: String, retryable: Bool = false) {
        guard !stopping else { return }
        trace("ERROR \(message)")
        if !retryable { classicPolicy.recordFailure() }
        stopClassic()
        errorMessage = message
        phase = .failed(message)
        if retryable { scheduleReconnect() }
    }

    private func scheduleReconnect() {
        guard !suspended, !shuttingDown, let uid = output?.uid, let delay = classicPolicy.nextReconnectDelay() else { return }
        cancelReconnect()
        let generation = reconnectGeneration
        isReconnecting = true
        reconnect = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.reconnectGeneration == generation, self.output?.uid == uid,
                      !self.suspended, !self.shuttingDown, !self.classicPolicy.userSuppressed else { return }
                self.reconnect = nil
                self.isReconnecting = false
                self.beginClassicConnection()
            }
        }
    }

    private func sonyConnectionChanged(_ status: SonyV1ClientConnectionState) {
        guard family == .sony, !stopping else { return }
        switch status {
        case .disconnected: phase = .idle
        case .connecting: phase = .connecting
        case .ready:
            phase = .ready
            identityVerified = true
            classicPolicy.confirmedConnection()
        case .failed(let message, let retryable): failClassic(message, retryable: retryable)
        }
    }

    private func sonyReadingsChanged(_ reading: SonyV1State) {
        guard family == .sony, !stopping else { return }
        state.battery = reading.batteryPercent
        if let mode = reading.noiseMode {
            let actual = Self.noiseMode(from: mode)
            state.noiseMode = actual
            supportedNoiseModes = [.off, .cancellation, .transparency]
            if reading.windReductionSupported { supportedNoiseModes.append(.windReduction) }
        }
    }

    private static func noiseMode(from mode: SonyV1NoiseMode) -> NoiseMode {
        switch mode {
        case .off: return .off
        case .noiseCancellation: return .cancellation
        case .ambient: return .transparency
        case .windReduction: return .windReduction
        }
    }

    private func oppoConnectionChanged(_ status: OppoRFCOMMStatus) {
        guard family == .oppo, !stopping else { return }
        switch status {
        case .idle: phase = .idle
        case .connecting: phase = .connecting
        case .connected:
            phase = .verifying
            guard sendOppo(.productID), sendOppo(.battery), sendOppo(.noiseControl, [0x01, 0x01]) else { return }
            armDeadline(seconds: 8) { $0.failClassic("OPPO 初始读取超时", retryable: true) }
        case .failed(let message, let retryable): failClassic(message, retryable: retryable)
        }
    }

    private func receiveOppo(_ data: Data) {
        guard family == .oppo, !stopping else { return }
        for message in oppoParser.append(data) {
            trace(String(format: "RX OPPO %04X [%dB]", message.command, message.payload.count))
            switch message.command {
            case 0x8103:
                if let product = OppoModelProfile.productID(from: message.payload) {
                    oppoProductReceived = true
                    oppoProfile = OppoModelProfile.profile(for: product)
                }
            case 0x8106:
                if let battery = OppoBatteryCodec.decode(message.payload) { state.battery = battery.lowestEarbudLevel }
            case 0x810C:
                if let mode = OppoNoiseCodec.decodeReport(message.payload), oppoProfile != nil {
                    state.noiseMode = mode
                    confirmNoiseReadback(mode)
                }
            default:
                if let event = OppoEventCodec.decode(message) {
                    switch event {
                    case .battery(let reading): state.battery = reading.lowestEarbudLevel
                    case .noiseMode(let mode):
                        if oppoProfile != nil { state.noiseMode = mode; confirmNoiseReadback(mode) }
                    }
                }
            }
            if phase == .verifying, oppoProductReceived, state.battery != nil {
                cancelDeadline()
                phase = .ready
                identityVerified = true
                classicPolicy.confirmedConnection()
            }
            supportedNoiseModes = oppoProfile != nil && state.noiseMode != nil ? [.off, .cancellation, .transparency] : []
        }
    }

    private func confirmNoiseReadback(_ actual: NoiseMode) {
        guard pendingNoiseMode != nil, noiseReadback.confirms(actual) else { return }
        cancelDeadline()
        pendingNoiseMode = nil
        noiseReadback.clear()
        busy = false
    }

    @discardableResult
    private func sendOppo(_ command: OppoCommand, _ payload: [UInt8] = []) -> Bool {
        let frame = OppoWire.encode(command: command.rawValue, sequence: takeSequence(), payload: payload)
        trace(String(format: "TX OPPO %04X", command.rawValue))
        guard oppo.send(frame) == 0 else { failClassic("OPPO 命令发送失败"); return false }
        return true
    }

    private func takeSequence() -> UInt8 {
        let result = sequence
        sequence = sequence >= 254 ? 1 : sequence + 1
        return result
    }

    private func trace(_ line: String) {
        guard !stopping else { return }
        diagnosticLines.append(line)
        if diagnosticLines.count > 80 { diagnosticLines.removeFirst(diagnosticLines.count - 80) }
    }

    private func armDeadline(seconds: TimeInterval, action: @escaping @MainActor (HeadphoneController) -> Void) {
        cancelDeadline()
        let generation = deadlineGeneration
        deadline = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.deadlineGeneration == generation else { return }
                action(self)
            }
        }
    }

    private func cancelDeadline() {
        deadlineGeneration &+= 1
        deadline?.invalidate()
        deadline = nil
    }

    private func cancelReconnect() {
        reconnectGeneration &+= 1
        reconnect?.invalidate()
        reconnect = nil
        isReconnecting = false
    }
}
