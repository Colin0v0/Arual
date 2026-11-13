import Combine
import CoreAudio
import Foundation

public struct HeadphoneReadings: Equatable {
    public var battery: HeadphoneBatteryReading?
    public var noiseMode: NoiseMode?
    public init(battery: HeadphoneBatteryReading? = nil, noiseMode: NoiseMode? = nil) {
        self.battery = battery
        self.noiseMode = noiseMode
    }
}

/// 统一界面状态，不把厂商协议混成一套“通用指令”。
/// B&W 走 BLE RPC；Sony MDR、OPPO Enco、Bose BMAP 与 Sennheiser GAIA
/// 分别使用各自确认的经典蓝牙控制服务。
@MainActor
public final class HeadphoneController: ObservableObject {
    @Published public private(set) var phase: HeadphonePhase = .idle
    @Published public private(set) var state = HeadphoneReadings()
    @Published public private(set) var candidates: [HeadphoneCandidate] = []
    @Published public private(set) var busy = false
    @Published public private(set) var identityVerified = false
    @Published public private(set) var pendingNoiseMode: NoiseMode?
    @Published public private(set) var supportedNoiseModes: [NoiseMode] = []
    @Published public private(set) var capabilities = HeadphoneCapabilities.none
    @Published public private(set) var modelProfile: HeadphoneModelProfile?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var diagnosticLines: [String] = []
    @Published public private(set) var family: HeadphoneFamily?
    @Published public private(set) var displayName = "耳机"
    @Published public private(set) var isReconnecting = false
    @Published public private(set) var isAwaitingWear = false
    @Published public private(set) var isRouteAuthorized = true
    public private(set) var boundOutputUID: String?

    @Published public private(set) var appleWearState: AppleHeadphoneWearState = .unknown
    public var showsNoiseControls: Bool { family != .apple || appleWearState.allowsModeControl }

    private let appleHardware: AppleHeadphoneHardware
    private let bowersWilkins = BowersWilkinsController()
    private let sony = SonyV1Client()
    private let oppo = OppoRFCOMMTransport()
    private let bose: any BoseControlTransport
    private let sennheiser: SennheiserClient
    private let validateClassicTarget: (String) throws -> Void
    private var oppoParser = OppoFrameParser()
    private var oppoProfile: OppoModelProfile?
    private var oppoProductReceived = false
    private var boseDecoder = BoseBMAPDecoder()
    private var boseModel: BoseBMAPModel?
    private var boseConnectionModel: BoseBMAPModel?
    private var boseInitializationPending = false
    private var boseModePollTask: Task<Void, Never>?
    private var boseCurrentModeReceived = false
    private var boseSwitchVerificationPending = false
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
    private var appleNeedsRetry = false
    /// 停止控制是按物理 UID 保存的用户意图，路由短暂变未知或 HAL ID 变化不能偷偷重新启用。
    private var suppressedControlUIDs: Set<String> = []
    private var stopping = false
    private var suspended = false
    private var shuttingDown = false

    public convenience init() { self.init(appleHardware: .live) }

    public convenience init(appleHardware: AppleHeadphoneHardware) {
        self.init(appleHardware: appleHardware, boseTransport: BoseRFCOMMTransport(),
                  validateClassicTarget: HeadphoneConnectionGuard.check)
    }

    /// 只注入边界用于测试，不增加运行时协议替代或忽略身份检查的路径。
    convenience init(appleHardware: AppleHeadphoneHardware, boseTransport: any BoseControlTransport,
                     validateClassicTarget: @escaping (String) throws -> Void) {
        self.init(appleHardware: appleHardware, boseTransport: boseTransport,
                  sennheiserTransport: SennheiserRFCOMMTransport(), validateClassicTarget: validateClassicTarget)
    }

    init(appleHardware: AppleHeadphoneHardware, boseTransport: any BoseControlTransport,
         sennheiserTransport: any SennheiserControlTransport,
         validateClassicTarget: @escaping (String) throws -> Void) {
        self.sennheiser = SennheiserClient(transport: sennheiserTransport)
        self.appleHardware = appleHardware
        self.bose = boseTransport
        self.validateClassicTarget = validateClassicTarget
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
        bose.onStatusChange = { [weak self] in self?.boseConnectionChanged($0) }
        bose.onData = { [weak self] in self?.receiveBose($0) }
        sennheiser.onConnectionChange = { [weak self] in self?.sennheiserConnectionChanged($0) }
        sennheiser.onStateChange = { [weak self] in self?.sennheiserReadingsChanged($0) }
        sennheiser.onNoiseWriteSent = { [weak self] in self?.noiseReadback.didSendWrite() }
        sennheiser.onNoiseVerificationSent = { [weak self] in self?.noiseReadback.didSendVerification() }
        sennheiser.onNoiseConfirmed = { [weak self] in self?.confirmNoiseReadback($0) }
        sennheiser.onLog = { [weak self] in self?.trace($0) }
    }

    public func updateOutput(_ newOutput: AudioOutput?) {
        let newFamily = newOutput.flatMap(family(for:))
        let target = newFamily == nil ? nil : newOutput
        if isRouteAuthorized != (target != nil) { isRouteAuthorized = target != nil }
        let identityChanged = target?.uid != output?.uid || newFamily != family
        let appleHandleChanged = newFamily == .apple && target?.id != output?.id
        if identityChanged || appleHandleChanged {
            stopClassic()
            cancelAppleOperation()
            bowersWilkins.updateOutput(nil)
            output = target
            appleNeedsRetry = false
            isAwaitingWear = false
            family = newFamily
            displayName = target?.name ?? "耳机"
            modelProfile = if let target, let newFamily {
                HeadphoneModelCatalog.profile(for: target.name, family: newFamily)
            } else {
                nil
            }
            errorMessage = nil
            diagnosticLines = []
            classicPolicy.updateOutput(target?.uid)
            phase = .idle
            clearCapabilities()
        } else {
            // 同一副耳机的 HAL ID/名称可随通话模式变化。Apple 必须废弃旧 HAL 写任务；
            // B&W/Sony/OPPO/Bose/Sennheiser 的物理控制连接绑定 UID，
            // 更新音频句柄即可，不无故断开 BLE/RFCOMM。
            output = target
            let name = target?.name ?? "耳机"
            if displayName != name {
                displayName = name
                // Bose 已由产品 ID 核验的 profile 不能被同一设备的改名覆盖。
                if boseModel == nil && !sennheiser.isIdentified {
                    modelProfile = if let target, let family {
                        HeadphoneModelCatalog.profile(for: target.name, family: family)
                    } else {
                        nil
                    }
                }
            }
        }
        bowersWilkins.setRouteAuthorization(isRouteAuthorized)
        guard !suspended, !shuttingDown else { return }
        if let target, suppressedControlUIDs.contains(target.uid) {
            phase = .idle
            return
        }
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
        // 已确认的 HAL 能力优先于用户可编辑的名称，不能把改名为 Px7 的 AirPods 交给 BLE 驱动。
        if appleHardware.isSupported(output.id) { return .apple }
        return HeadphoneFamily.recognize(output.name)
    }

    /// 视图只查询能力，不改变当前连接状态。
    public func supports(_ output: AudioOutput?) -> Bool {
        guard let output else { return false }
        return family(for: output) != nil
    }

    /// 停止控制不等于断开蓝牙音频；Apple 与其他厂商共用同一用户授权语义。
    public var canDisconnect: Bool { family != nil }
    public var isControlSuppressed: Bool {
        guard let output else { return false }
        return suppressedControlUIDs.contains(output.uid)
    }

    public func outputUnavailable() {
        appleWearState = .unknown
        updateOutput(nil)
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
        errorMessage = nil
        isReconnecting = false
        if let output { suppressedControlUIDs.insert(output.uid) }
        if family == .bowersWilkins { bowersWilkins.disconnect(); copyBowersWilkinsState() }
        else if family == .apple {
            cancelAppleOperation()
            state = HeadphoneReadings()
            clearCapabilities()
            boundOutputUID = nil
            identityVerified = false
            errorMessage = nil
            phase = .idle
        } else { classicPolicy.suppress(); stopClassic(); phase = .idle }
    }

    public func retryAutomaticConnection(output: AudioOutput) {
        guard !suspended, !shuttingDown,
              self.output?.uid == output.uid, self.output?.id == output.id else { return }
        suppressedControlUIDs.remove(output.uid)
        // 目标已经由模型绑定；不要先触发自动连接，再重复发起一次手动连接。
        if family == .bowersWilkins { bowersWilkins.retryAutomaticConnection(output: output) }
        else if family == .apple { appleNeedsRetry = false; refreshApple() }
        else {
            stopClassic()
            classicPolicy.manualAttempt()
            beginClassicConnection()
        }
    }

    public func scan(output: AudioOutput) {
        guard family == .bowersWilkins, self.output?.uid == output.uid, self.output?.id == output.id else { return }
        bowersWilkins.scan(output: output)
    }

    public func connect(_ id: UUID) {
        guard family == .bowersWilkins else { return }
        bowersWilkins.connect(id)
    }

    private var hasAuthorizedBinding: Bool {
        identityVerified && boundOutputUID != nil && boundOutputUID == output?.uid
            && isRouteAuthorized && !isControlSuppressed && !suspended && !shuttingDown
    }

    /// 已验证且空闲的物理控制连接不必因音频路由过渡被拆掉；过渡期间只保留连接，不允许发命令。
    public func pauseRouteAuthorization() -> Bool {
        guard phase == .ready, !busy, identityVerified, !suspended, !shuttingDown else { return false }
        if isRouteAuthorized { isRouteAuthorized = false }
        bowersWilkins.setRouteAuthorization(false)
        return true
    }

    public func refresh() {
        guard phase == .ready, !busy, hasAuthorizedBinding else { return }
        errorMessage = nil
        switch family {
        case .bowersWilkins: bowersWilkins.refresh()
        case .sony: sony.refresh()
        case .sennheiser: sennheiser.refresh()
        case .oppo: sendOppo(.battery); sendOppo(.noiseControl, [0x01, 0x01])
        case .bose:
            guard sendBose(BoseBMAPProtocol.queryBattery(), label: "battery") else { return }
            sendBose(BoseBMAPProtocol.queryCurrentMode(), label: "current mode")
        case .apple: refreshApple()
        case nil: break
        }
    }

    public func setNoiseMode(_ mode: NoiseMode) {
        guard phase == .ready, !busy, hasAuthorizedBinding, showsNoiseControls,
              supportedNoiseModes.contains(mode), state.noiseMode != mode else { return }
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
        case .bose:
            guard let index = BoseBMAPProtocol.modeIndex(for: mode) else {
                failClassic("该 Bose 型号没有经过确认的噪声模式映射")
                return
            }
            guard sendBose(BoseBMAPProtocol.switchMode(index: index), label: "switch mode \(index)") else {
                return
            }
            noiseReadback.didSendWrite()
            // START 只代表命令已发出。等耳机返回 RESULT 后再 GET 当前模式，
            // 避免异步固件尚未应用新模式时把旧回包误当成确认结果。
            boseSwitchVerificationPending = true
        case .sennheiser:
            guard sennheiser.setNoiseMode(mode) else {
                // 正在刷新时没有排队写入，不把一次未发送的请求留在忙碌状态。
                pendingNoiseMode = nil; noiseReadback.clear(); busy = false
                return
            }
        case .apple:
            writeAppleNoiseMode(mode)
            return
        default: return
        }
        guard phase == .ready, pendingNoiseMode != nil else { return }
        armDeadline(seconds: 8) { $0.failClassic("耳机没有确认噪声模式变更") }
    }

    private func copyBowersWilkinsState() {
        guard family == .bowersWilkins else { return }
        if isControlSuppressed {
            errorMessage = nil
            isReconnecting = false
            candidates = []
            state = HeadphoneReadings()
            clearCapabilities()
            boundOutputUID = nil
            identityVerified = false
            pendingNoiseMode = nil
            busy = false
            phase = bowersWilkins.phase == .disconnecting ? .disconnecting : .idle
            return
        }
        if let bound = bowersWilkins.boundOutputUID, bound != output?.uid {
            // 旧 BLE 连接的取消确认可能稍晚返回，不能把旧耳机读数挂到新目标名称下。
            state = HeadphoneReadings()
            clearCapabilities()
            boundOutputUID = nil
            identityVerified = false
            pendingNoiseMode = nil
            phase = .disconnecting
            return
        }
        phase = bowersWilkins.phase
        let batteryReading: HeadphoneBatteryReading? = if bowersWilkins.state.battery != nil || bowersWilkins.state.isCharging != nil {
            HeadphoneBatteryReading(single: bowersWilkins.state.battery,
                                    isCharging: bowersWilkins.state.isCharging)
        } else {
            nil
        }
        state = HeadphoneReadings(battery: batteryReading, noiseMode: bowersWilkins.state.noiseMode)
        candidates = bowersWilkins.candidates
        busy = bowersWilkins.busy
        identityVerified = bowersWilkins.identityVerified
        boundOutputUID = bowersWilkins.boundOutputUID
        errorMessage = bowersWilkins.errorMessage
        pendingNoiseMode = bowersWilkins.pendingNoiseMode
        diagnosticLines = bowersWilkins.diagnosticLines
        let noiseModes = resolvedProfileNoiseModes(
            protocolModes: [.off, .cancellation, .transparency]
        )
        updateCapabilities(
            battery: state.battery?.hasLevel == true ? batteryCapabilityForDriver : nil,
            noise: state.noiseMode.map {
                HeadphoneNoiseCapability(modes: noiseModes, currentMode: $0)
            }
        )
        isReconnecting = bowersWilkins.isReconnecting
    }

    /// Apple 耳机每次刷新都直接读取 HAL；没有建立或维护另一条蓝牙控制连接。
    private func refreshApple() {
        guard !suspended, !shuttingDown, !busy, !appleNeedsRetry,
              let output, family == .apple else { return }
        do {
            try appleHardware.validateTarget(output)
            let snapshot = try appleHardware.snapshot(output.id)
            guard self.output?.uid == output.uid, family == .apple, !stopping else { return }
            acceptAppleSnapshot(snapshot, output: output)
            trace("APPLE HAL MODE \(snapshot.noiseMode.rawValue)")
        } catch {
            failApple(error.localizedDescription)
        }
    }

    /// 单耳、未佩戴和未知仍是已连接设备；只隐藏模式控制，不清空真实电量或断开绑定。
    private func acceptAppleSnapshot(_ snapshot: AppleHeadphoneSnapshot, output: AudioOutput) {
        appleWearState = snapshot.wearState
        isAwaitingWear = false
        var readings = HeadphoneReadings(noiseMode: snapshot.noiseMode)
        do {
            let battery = try appleHardware.battery(output)
            readings.battery = battery.map {
                HeadphoneBatteryReading(single: $0.main, left: $0.left, right: $0.right,
                                        caseLevel: $0.caseLevel)
            }
        } catch {
            trace("APPLE BATTERY ERROR \(error.localizedDescription)")
        }
        state = readings
        updateCapabilities(
            battery: readings.battery.map { battery in
                // 实际回包只有整机电量时，诊断和设置页也按单值能力显示。
                if battery.single != nil, battery.left == nil, battery.right == nil,
                   battery.caseLevel == nil {
                    return .single
                }
                return .earbudsWithCase
            },
            noise: HeadphoneNoiseCapability(
                modes: snapshot.supportedNoiseModes,
                currentMode: snapshot.noiseMode
            )
        )
        boundOutputUID = output.uid
        identityVerified = true
        errorMessage = nil
        phase = .ready
    }

    private func writeAppleNoiseMode(_ mode: NoiseMode) {
        guard let output, family == .apple else {
            failApple("当前没有可控制的 Apple 耳机")
            return
        }
        let generation = appleGeneration
        appleTask?.cancel()
        appleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.checkAppleAuthorization(output: output, generation: generation)
                try self.appleHardware.requestMode(mode, output)
                for _ in 0..<16 {
                    try await self.appleHardware.waitForReadback()
                    try self.checkAppleAuthorization(output: output, generation: generation)
                    let snapshot = try self.appleHardware.snapshot(output.id)
                    if !snapshot.wearState.allowsModeControl {
                        self.cancelAppleOperation()
                        self.acceptAppleSnapshot(snapshot, output: output)
                        return
                    }
                    guard snapshot.noiseMode == mode else { continue }
                    self.cancelDeadline()
                    self.acceptAppleSnapshot(snapshot, output: output)
                    self.pendingNoiseMode = nil
                    self.noiseReadback.clear()
                    self.busy = false
                    self.errorMessage = nil
                    self.phase = .ready
                    self.appleTask = nil
                    self.trace("APPLE HAL SET \(mode.rawValue)")
                    return
                }
                throw AudioFailure("Apple 耳机没有确认聆听模式切换")
            } catch {
                // 旧目标或被取消的任务不能发布新状态，更不能覆盖另一副耳机的读数。
                guard !Task.isCancelled, self.appleGeneration == generation,
                      self.output?.uid == output.uid, self.output?.id == output.id,
                      self.family == .apple else { return }
                if error is AppleHeadphoneNotWorn {
                    self.cancelAppleOperation()
                    self.refreshApple()
                    return
                }
                if let failure = error as? AudioFailure, failure.status == kAudioHardwareIllegalOperationError {
                    // nope 只表示本次 SET 被拒绝。只读回当前事实，不重发，也不摧毁仍可读取的控制连接。
                    do {
                        try self.checkAppleAuthorization(output: output, generation: generation)
                        let snapshot = try self.appleHardware.snapshot(output.id)
                        if !snapshot.wearState.allowsModeControl {
                            self.cancelAppleOperation()
                            self.acceptAppleSnapshot(snapshot, output: output)
                            return
                        }
                        self.cancelAppleOperation()
                        self.acceptAppleSnapshot(snapshot, output: output)
                        self.isAwaitingWear = false
                        self.phase = .ready
                        self.errorMessage = "Apple 耳机拒绝了本次模式切换，当前模式已重新读取；请确认佩戴状态后再操作"
                        return
                    } catch {
                        self.failApple("模式写入被拒绝，且无法确认当前状态：\(error.localizedDescription)")
                        return
                    }
                }
                self.failApple(error.localizedDescription)
            }
        }
    }

    private func checkAppleAuthorization(output: AudioOutput, generation: UInt64) throws {
        try Task.checkCancellation()
        guard appleGeneration == generation, self.output?.uid == output.uid,
              self.output?.id == output.id, family == .apple,
              isRouteAuthorized, !suspended, !shuttingDown, !stopping else { throw CancellationError() }
        try appleHardware.validateTarget(output)
    }

    private func failApple(_ message: String) {
        appleWearState = .unknown
        appleNeedsRetry = true
        cancelAppleOperation()
        state = HeadphoneReadings()
        clearCapabilities()
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
        guard !suspended, !shuttingDown, let output,
              family == .sony || family == .oppo || family == .bose || family == .sennheiser else { return }
        do {
            try validateClassicTarget(output.uid)
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
            clearCapabilities()
            trace("CONNECT \(family!.rawValue) FROM CORE AUDIO ADDRESS")
            if family == .sony { sony.connect(address: bytes.joined(separator: ":"), deviceName: output.name, outputUID: output.uid) }
            else if family == .oppo { oppo.connect(address: bytes.joined(separator: ":"), outputUID: output.uid) }
            else if family == .sennheiser {
                sennheiser.connect(address: bytes.joined(separator: ":"), outputUID: output.uid)
            } else {
                guard let candidate = BoseBMAPModel.allCases.first(where: { $0.catalogID == modelProfile?.id }) else {
                    throw AudioFailure("Bose 型号尚未登记控制端点")
                }
                boseConnectionModel = candidate
                bose.connect(address: bytes.joined(separator: ":"), outputUID: output.uid, endpoint: candidate.endpoint)
            }
        } catch { failClassic(error.localizedDescription) }
    }

    private func stopClassic() {
        stopping = true
        cancelDeadline()
        cancelReconnect()
        sony.disconnect()
        oppo.disconnect()
        bose.disconnect()
        sennheiser.disconnect()
        oppoParser.reset()
        oppoProfile = nil
        oppoProductReceived = false
        boseDecoder.reset()
        boseModel = nil
        boseConnectionModel = nil
        boseInitializationPending = false
        boseModePollTask?.cancel(); boseModePollTask = nil
        boseCurrentModeReceived = false
        boseSwitchVerificationPending = false
        sequence = 1
        state = HeadphoneReadings()
        candidates = []
        clearCapabilities()
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
        state.battery = if reading.batteryPercent != nil || reading.isCharging != nil {
            HeadphoneBatteryReading(single: reading.batteryPercent, isCharging: reading.isCharging)
        } else {
            nil
        }
        var noise: HeadphoneNoiseCapability?
        if let mode = reading.noiseMode {
            let actual = Self.noiseMode(from: mode)
            state.noiseMode = actual
            var protocolModes: [NoiseMode] = [.off, .cancellation, .transparency]
            if reading.windReductionSupported {
                protocolModes.append(.windReduction)
            }
            let modes = resolvedProfileNoiseModes(
                protocolModes: protocolModes,
                confirmedOptionalModes: reading.windReductionSupported ? [.windReduction] : []
            )
            noise = HeadphoneNoiseCapability(
                modes: modes,
                currentMode: actual,
                ambientLevelRange: 1...20
            )
        }
        updateCapabilities(
            battery: reading.batteryPercent == nil ? nil : batteryCapabilityForDriver,
            noise: noise
        )
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
                if let battery = OppoBatteryCodec.decode(message.payload) {
                    state.battery = battery.batteryReading
                }
            case 0x810C:
                if let mode = OppoNoiseCodec.decodeReport(message.payload), oppoProfile != nil {
                    state.noiseMode = mode
                    confirmNoiseReadback(mode)
                }
            default:
                if let event = OppoEventCodec.decode(message) {
                    switch event {
                    case .battery(let reading):
                        state.battery = reading.batteryReading
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
            let oppoNoiseModes: [NoiseMode] = if let oppoProfile {
                [.off, .cancellation, .transparency].filter { oppoProfile.noiseBits[$0] != nil }
            } else {
                []
            }
            updateCapabilities(
                battery: state.battery?.hasLevel == true ? batteryCapabilityForDriver : nil,
                noise: state.noiseMode.flatMap { currentMode in
                    guard !oppoNoiseModes.isEmpty else { return nil }
                    return HeadphoneNoiseCapability(modes: oppoNoiseModes, currentMode: currentMode)
                }
            )
        }
    }

    private func sennheiserConnectionChanged(_ status: SennheiserRFCOMMStatus) {
        guard family == .sennheiser, !stopping else { return }
        switch status {
        case .idle: phase = .idle
        case .connecting: phase = .connecting
        case .connected:
            // Client 只有真实身份与两项开关均已读取时才回报就绪。
            phase = .ready; identityVerified = true
            modelProfile = HeadphoneModelCatalog.profiles.first { $0.id == "sennheiser-accentum-wireless" }
            classicPolicy.confirmedConnection()
        case .failed(let message, let retryable): failClassic(message, retryable: retryable)
        }
    }

    private func sennheiserReadingsChanged(_ reading: SennheiserReadings) {
        guard family == .sennheiser, !stopping, sennheiser.isIdentified else { return }
        state = HeadphoneReadings(battery: reading.battery.map { HeadphoneBatteryReading(single: $0) },
                                  noiseMode: reading.noiseMode)
        updateCapabilities(battery: reading.battery == nil ? nil : .single,
                           noise: reading.noiseMode.map {
            HeadphoneNoiseCapability(modes: [.off, .cancellation, .transparency], currentMode: $0)
        })
    }

    private func boseConnectionChanged(_ status: BoseRFCOMMStatus) {
        guard family == .bose, !stopping else { return }
        switch status {
        case .idle:
            phase = .idle
        case .connecting:
            phase = .connecting
        case .connected:
            phase = .verifying
            boseDecoder.reset()
            boseModel = nil
            boseCurrentModeReceived = false
            boseSwitchVerificationPending = false
            // 通道打开不等于型号已确认；先只查询产品身份，不能把其他型号的
            // 自发回包当成本型号能力，也不提前向未知型号发送功能命令。
            guard let candidate = boseConnectionModel else { failClassic("Bose 控制端点尚未确认"); return }
            boseInitializationPending = candidate.requiresInitialization
            let initial = candidate.requiresInitialization
                ? BoseBMAPProtocol.initializeLegacyProduct() : BoseBMAPProtocol.queryProductIdentity()
            guard sendBose(initial, label: "initial identity query") else { return }
            armDeadline(seconds: 8) { $0.failClassic("Bose 初始读取超时", retryable: true) }
        case .failed(let message, let retryable):
            failClassic(message, retryable: retryable)
        }
    }

    private func receiveBose(_ data: Data) {
        guard family == .bose, !stopping, !suspended, !shuttingDown,
              phase == .verifying || phase == .ready else { return }
        let frames: [BoseBMAPFrame]
        do { frames = try boseDecoder.append(data) }
        catch { failClassic(error.localizedDescription); return }
        for frame in frames {
            trace(String(format: "RX BOSE [%d.%d] op=%d [%dB]",
                         frame.functionBlock, frame.function,
                         frame.operation?.rawValue ?? 0, frame.payload.count))
            if frame.operation == .error {
                let payload = [UInt8](frame.payload).map { String(format: "%02X", $0) }.joined(separator: " ")
                failClassic("Bose 返回错误 \(payload)", retryable: false)
                return
            }

            if boseInitializationPending {
                if BoseBMAPProtocol.isStatus(frame, block: 0, function: 1) {
                    boseInitializationPending = false
                    guard sendBose(BoseBMAPProtocol.queryProductIdentity(), label: "product identity") else { return }
                }
                continue
            }

            if boseSwitchVerificationPending, let boseModel,
               BoseBMAPProtocol.isModeSwitchAcknowledgement(frame, model: boseModel) {
                boseSwitchVerificationPending = false
                guard sendBose(BoseBMAPProtocol.queryCurrentMode(), label: "verify mode") else {
                    return
                }
                noiseReadback.didSendVerification()
                if frame.operation == .processing { startBoseModePolling() }
            }

            if let productID = BoseBMAPProtocol.parseProductID(frame) {
                guard let model = BoseBMAPModel(rawValue: productID) else {
                    failClassic(String(format: "当前 Bose 产品 ID 0x%04X 尚未通过协议验收", productID))
                    return
                }
                guard let candidate = boseConnectionModel, candidate.endpoint == model.endpoint,
                      candidate.requiresInitialization == model.requiresInitialization else {
                    failClassic("Bose 产品身份与已选择的控制端点不匹配")
                    return
                }
                if let boseModel, boseModel != model {
                    // 同一条控制连接不允许中途换产品，必须重新连接并核验身份。
                    failClassic("Bose 产品身份在控制连接期间发生变化")
                    return
                }
                if boseModel == nil {
                    guard let profile = HeadphoneModelCatalog.profiles.first(where: { $0.id == model.catalogID }) else {
                        failClassic("Bose 型号能力表不完整")
                        return
                    }
                    boseModel = model
                    // 名称只是连接候选；诊断和能力表最终必须跟随真实 Product ID。
                    modelProfile = profile
                    guard sendBose(BoseBMAPProtocol.queryBattery(), label: "battery"),
                          sendBose(BoseBMAPProtocol.queryCurrentMode(), label: "current mode") else { return }
                }
            }
            // 身份尚未确认时，仅处理产品查询响应；电量和模式都不能提前发布。
            guard let boseModel else { continue }
            if let battery = BoseBMAPProtocol.parseBattery(frame, model: boseModel) {
                state.battery = battery.hasLevel ? battery : nil
            }
            if BoseBMAPProtocol.isStatus(frame, block: BoseBMAPProtocol.audioModesBlock,
                                         function: BoseBMAPProtocol.currentMode),
               !frame.payload.isEmpty {
                boseCurrentModeReceived = true
                // Immersion、自定义模式等不能沿用上次 Quiet/Aware 的选中状态。
                state.noiseMode = BoseBMAPProtocol.parseNoiseMode(frame)
                if let mode = state.noiseMode { confirmNoiseReadback(mode) }
            }

            if phase == .verifying, state.battery?.hasLevel == true, boseCurrentModeReceived {
                cancelDeadline()
                phase = .ready
                identityVerified = true
                classicPolicy.confirmedConnection()
            }
            updateBoseCapabilities()
        }
    }

    /// PROCESSING 只代表处理中：有界轮询同一 GET，不重复 SET，也不切换后端。
    /// 原有 8 秒 deadline 仍负责失败；轮询成功或停止控制时立即取消。
    private func startBoseModePolling() {
        boseModePollTask?.cancel()
        boseModePollTask = Task { @MainActor [weak self] in
            for _ in 0..<30 {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                guard let self, !Task.isCancelled, self.phase == .ready,
                      self.pendingNoiseMode != nil, self.hasAuthorizedBinding else { return }
                guard self.sendBose(BoseBMAPProtocol.queryCurrentMode(), label: "verify processing mode") else { return }
                self.noiseReadback.didSendVerification()
            }
        }
    }

    private func updateBoseCapabilities() {
        guard family == .bose, let boseModel else { return }
        updateCapabilities(
            battery: state.battery?.hasLevel == true ? boseModel.batteryCapability : nil,
            // Quiet/Aware 已由产品 ID 和协议确认。当前若停在 Immersion 等
            // 尚未映射的厂商模式，仍展示可切换模式，但不伪造任何选中项。
            noise: boseCurrentModeReceived ? HeadphoneNoiseCapability(
                modes: boseModel.noiseModes,
                currentMode: state.noiseMode
            ) : nil
        )
    }

    @discardableResult
    private func sendBose(_ data: Data, label: String) -> Bool {
        trace("TX BOSE \(label)")
        let result = bose.send(data)
        guard result == kIOReturnSuccess else {
            // 传输可以同步回调 failed，且已触发 stopClassic/有界重连。
            // 不能再次失败处理，否则会清除原错误和刚排好的重连任务。
            if case .failed = phase { return false }
            failClassic("Bose 命令发送失败（\(result)）")
            return false
        }
        return true
    }

    private func confirmNoiseReadback(_ actual: NoiseMode) {
        guard pendingNoiseMode != nil, noiseReadback.confirms(actual) else { return }
        cancelDeadline()
        pendingNoiseMode = nil
        noiseReadback.clear()
        boseModePollTask?.cancel(); boseModePollTask = nil
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

    /// 能力和模式列表只通过这一个入口发布，避免界面状态与诊断状态分叉。
    private func updateCapabilities(
        battery: HeadphoneBatteryCapability?,
        noise: HeadphoneNoiseCapability?
    ) {
        let next = HeadphoneCapabilities(battery: battery, noise: noise)
        capabilities = next
        supportedNoiseModes = next.noiseModes
    }

    private func clearCapabilities() {
        updateCapabilities(battery: nil, noise: nil)
    }

    /// 电量形状属于驱动契约，不由型号名猜测。
    private var batteryCapabilityForDriver: HeadphoneBatteryCapability? {
        switch family {
        case .apple, .oppo: return .earbudsWithCase
        case .bose: return boseModel?.batteryCapability
        case .bowersWilkins, .sony, .sennheiser: return .single
        case nil: return nil
        }
    }

    /// 型号表负责档数，协议回包负责证明控制通道确实存在。
    private func resolvedProfileNoiseModes(
        protocolModes: [NoiseMode],
        confirmedOptionalModes: Set<NoiseMode> = []
    ) -> [NoiseMode] {
        guard let modelProfile else { return protocolModes }
        return modelProfile.resolvedNoiseModes(confirmedOptionalModes: confirmedOptionalModes)
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
