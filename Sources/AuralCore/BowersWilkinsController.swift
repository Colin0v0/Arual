import Combine
import CoreBluetooth
import Foundation

public struct HeadphoneCandidate: Identifiable, Equatable {
    public let id: UUID
    public let name: String
}

public enum HeadphonePhase: Equatable {
    case idle, starting, scanning, choosing, connecting, discovering, verifying, ready, disconnecting
    case failed(String)
    public var title: String {
        switch self {
        case .idle: return "耳机控制尚未连接"
        case .starting: return "等待蓝牙授权与就绪"
        case .scanning: return "正在寻找耳机…"
        case .choosing: return "请选择你的耳机"
        case .connecting: return "正在连接控制通道…"
        case .discovering: return "正在验证耳机服务…"
        case .verifying: return "正在验证耳机"
        case .ready: return "已连接"
        case .disconnecting: return "正在断开控制通道…"
        case .failed: return "控制连接失败"
        }
    }
}

/// B&W RPC 控制生命周期；设备家族规则、通用广播与 ANC 映射复用 HeadBridge。
/// 所有 delegate 由显式的 main queue 驱动，与界面状态处在同一执行域。
@MainActor
public final class BowersWilkinsController: NSObject, ObservableObject {
    @Published public private(set) var phase: HeadphonePhase = .idle
    @Published public private(set) var candidates: [HeadphoneCandidate] = []
    @Published public private(set) var state = BowersWilkinsState()
    @Published public private(set) var busy = false
    @Published public private(set) var identityVerified = false
    @Published public private(set) var pendingNoiseMode: NoiseMode?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var diagnosticLines: [String] = []
    public private(set) var boundOutputUID: String?
    public var isReconnecting: Bool { reconnectTimer != nil }

    private var central: CBCentralManager?
    private var discovered: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var requestCharacteristic: CBCharacteristic?
    private var responseCharacteristic: CBCharacteristic?
    private var eventCharacteristic: CBCharacteristic?
    private var pendingServices: Set<ObjectIdentifier> = []
    private var pendingSubscriptions: Set<CBUUID> = []
    private var deadline: Timer?
    private var deadlineGeneration: UInt64 = 0
    private var writeAcknowledged = false
    private var reply: BWRPCMessage?

    private enum Purpose {
        case identify, refresh, setNoise(NoiseMode), confirmNoise(NoiseMode)

        var isIdentityCheck: Bool {
            if case .identify = self { return true }
            return false
        }
    }
    private struct Request {
        let command: BWRPCCommand
        let payload: MessagePackValue?
        let purpose: Purpose
    }
    private var queue: [Request] = []
    private var current: Request?
    private var autoConnection = HeadphoneAutoConnection()
    private var observedOutput: AudioOutput?
    private var selectedCandidateName: String?
    private var noiseProfile: BowersWilkinsNoiseProfile = .unverified
    private var scanningAutomatically = false
    private var scanStartedAt: Date?
    private var selectionTimer: Timer?
    private var selectionGeneration: UInt64 = 0
    private var reconnectTimer: Timer?
    private var reconnectGeneration: UInt64 = 0
    private var reconnectAfterClose = false
    private var closingConnection = false
    private var suspended = false
    private var shuttingDown = false
    private var routeAuthorized = true
    private var bindingConfirmed = false
    private var previousRadioState: CBManagerState = .unknown

    public override init() {
        super.init()
    }

    /// 保留 BLE 会话，但阻止未确认路由期间扫描、连接或发送排队请求。
    public func setRouteAuthorization(_ authorized: Bool) {
        guard routeAuthorized != authorized else { return }
        routeAuthorized = authorized
        if authorized { sendNext() }
    }

    /// 由真实的系统默认输出驱动；同一个 UID 的轮询不会反复触发连接。
    public func updateOutput(_ output: AudioOutput?) {
        let target: AudioOutput?
        if let output, output.isBluetooth, HeadphoneFamily.recognize(output.name) == .bowersWilkins { target = output }
        else { target = nil }
        observedOutput = target
        if autoConnection.observe(.confirmed(target?.uid)) {
            errorMessage = nil
            closeConnection()
        }
        startAutomaticallyIfNeeded()
    }

    private func startAutomaticallyIfNeeded() {
        guard routeAuthorized, !suspended, !shuttingDown, peripheral == nil, reconnectTimer == nil,
              phase == .idle || isFailed, let output = observedOutput,
              autoConnection.takeInitialAttempt() else { return }
        beginConnectionScan(output: output, automatically: true)
    }

    /// 快照未知时停用硬件，但不把未知伪装成输出切换。
    public func outputUnavailable() {
        autoConnection.observe(.unavailable)
        observedOutput = nil
        closeConnection()
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    public func suspend() {
        suspended = true
        closeConnection()
    }

    public func resume() {
        suspended = false
        autoConnection.radioOrWakeRecovered()
        // 等 AppModel 取得唤醒后的真实输出后，由 updateOutput 决定是否启动。
    }

    public func shutdown() {
        shuttingDown = true
        closeConnection()
    }

    public func retryAutomaticConnection(output: AudioOutput) {
        guard peripheral == nil else { errorMessage = "请先等待当前控制通道断开"; return }
        guard output.isBluetooth, HeadphoneFamily.recognize(output.name) == .bowersWilkins else {
            errorMessage = "请先在系统输出中选择 B&W 耳机"; return
        }
        observedOutput = output
        autoConnection.updateOutput(output.uid)
        autoConnection.manualAttempt()
        beginConnectionScan(output: output, automatically: true)
    }

    /// 显式重新选择时才忽略旧绑定；它不是自动连接失败后的隐式替代分支。
    public func scan(output: AudioOutput) {
        guard peripheral == nil else { errorMessage = "请先等待当前控制通道断开"; return }
        guard output.isBluetooth, HeadphoneFamily.recognize(output.name) == .bowersWilkins else {
            errorMessage = "请先在系统输出中选择 B&W 耳机"; return
        }
        observedOutput = output
        autoConnection.updateOutput(output.uid)
        autoConnection.manualAttempt()
        beginConnectionScan(output: output, automatically: false)
    }

    private func beginConnectionScan(output: AudioOutput, automatically: Bool) {
        guard routeAuthorized, !suspended, !shuttingDown, peripheral == nil else { return }
        cancelReconnect()
        do {
            try HeadphoneRouteGuard.check(output.uid)
            // 每次都按同一个经典蓝牙地址验证；BLE UUID 会变化，不读取旧 UUID 锁死新连接。
        } catch { fail(error.localizedDescription); return }
        clearReadings()
        diagnosticLines = []
        candidates = []; discovered = [:]
        boundOutputUID = output.uid
        scanningAutomatically = automatically
        errorMessage = nil
        phase = .starting
        armDeadline(seconds: 15, message: "等待蓝牙就绪超时，请检查权限后手动重试")
        if let central { beginScan(central) }
        else {
            central = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    private func beginScan(_ central: CBCentralManager) {
        guard routeAuthorized, !suspended, !shuttingDown else { return }
        guard central.state == .poweredOn else {
            if central.state == .unknown || central.state == .resetting { return }
            fail("蓝牙未开启或未授权，请在系统设置中检查")
            return
        }
        central.stopScan()
        phase = .scanning
        scanStartedAt = Date()
        trace(scanningAutomatically ? "AUTO SCAN" : "MANUAL SCAN")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scheduleDeadline(seconds: 12) { controller in controller.finishScan() }
        do {
            cancelSelection()
            let generation = selectionGeneration
            selectionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.selectionGeneration == generation else { return }
                    self.evaluateAutomaticSelection()
                }
            }
        }
    }

    private func finishScan() {
        guard phase == .scanning else { return }
        central?.stopScan(); cancelDeadline(); cancelSelection()
        evaluateAutomaticSelection()
        guard phase == .scanning else { return }
        if candidates.isEmpty { fail("未发现耳机控制广播", reconnect: true) }
        else { phase = .choosing }
    }

    private func evaluateAutomaticSelection() {
        guard phase == .scanning, let output = observedOutput else { return }
        switch HeadphoneIdentity.selection(outputName: output.name, candidates: candidates) {
        case .choose(let id): connectCandidate(id)
        case .ambiguous:
            central?.stopScan(); cancelDeadline(); cancelSelection()
            phase = .choosing
        case .none: break
        }
    }

    public func connect(_ id: UUID) {
        autoConnection.manualAttempt()
        connectCandidate(id)
    }

    private func connectCandidate(_ id: UUID) {
        guard routeAuthorized, !suspended, !shuttingDown, phase == .scanning || phase == .choosing,
              let central, central.state == .poweredOn,
              let candidate = discovered[id], peripheral == nil else { return }
        do {
            guard let boundOutputUID else { throw AudioFailure("耳机输出绑定已丢失") }
            try HeadphoneRouteGuard.check(boundOutputUID)
        } catch { fail(error.localizedDescription); return }
        central.stopScan(); cancelDeadline(); cancelSelection()
        peripheral = candidate
        if let output = observedOutput, let item = candidates.first(where: { $0.id == id }) {
            selectedCandidateName = item.name
            noiseProfile = BowersWilkinsNoiseProfile.identify(outputName: output.name, advertisedName: item.name)
            trace("BLE CANDIDATE \(item.name)")
        }
        closingConnection = false
        candidate.delegate = self
        phase = .connecting
        candidates = []
        trace("BLE CONNECT")
        central.connect(candidate)
        armDeadline(seconds: 15, message: "连接耳机控制通道超时")
    }

    /// 用户主动断开/取消需要抑制自动连接，不能立即又被轮询接回。
    public func disconnect() {
        autoConnection.suppress()
        closeConnection()
    }

    private func closeConnection() {
        reconnectAfterClose = false
        cancelDeadline(); cancelSelection(); cancelReconnect()
        central?.stopScan()
        clearReadings()
        boundOutputUID = nil
        candidates = []; discovered = [:]
        if let peripheral, let central {
            if peripheral.state == .disconnected {
                peripheral.delegate = nil; self.peripheral = nil
                closingConnection = false; phase = .idle
            } else {
                closingConnection = true
                phase = .disconnecting
                central.cancelPeripheralConnection(peripheral)
            }
        } else { closingConnection = false; phase = .idle }
    }

    private func cancelSelection() {
        selectionGeneration &+= 1
        selectionTimer?.invalidate(); selectionTimer = nil
    }

    private func cancelReconnect() {
        reconnectGeneration &+= 1
        reconnectTimer?.invalidate(); reconnectTimer = nil
    }

    private func scheduleReconnect() {
        guard !suspended, !shuttingDown, let output = observedOutput,
              let delay = autoConnection.nextReconnectDelay() else { return }
        cancelReconnect()
        let generation = reconnectGeneration
        trace("BLE RECONNECT IN \(Int(delay))s")
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.reconnectGeneration == generation,
                      self.observedOutput?.uid == output.uid,
                      !self.suspended, !self.shuttingDown,
                      !self.autoConnection.userSuppressed, !self.autoConnection.failed else { return }
                self.reconnectTimer = nil
                self.beginConnectionScan(output: output, automatically: true)
            }
        }
    }

    public func refresh() {
        guard routeAuthorized, phase == .ready, !busy else { return }
        errorMessage = nil
        enqueueReads()
    }

    public func setNoiseMode(_ mode: NoiseMode) {
        guard routeAuthorized, phase == .ready, !busy, state.noiseMode != nil else { return }
        guard state.noiseMode != mode, let wireValue = noiseProfile.wireValue(for: mode) else { return }
        pendingNoiseMode = mode
        errorMessage = nil
        queue = [Request(command: BWRPCatalog.ancSet, payload: .int(Int64(wireValue)), purpose: .setNoise(mode))]
        sendNext()
    }

    private func clearReadings() {
        state = BowersWilkinsState(); busy = false; pendingNoiseMode = nil; identityVerified = false
        bindingConfirmed = false
        selectedCandidateName = nil
        queue = []; current = nil; reply = nil; writeAcknowledged = false
        requestCharacteristic = nil; responseCharacteristic = nil; eventCharacteristic = nil
        pendingServices = []; pendingSubscriptions = []
    }

    private func trace(_ line: String) {
        diagnosticLines.append(line)
        // 身份失败后会重新扫描，保留更长的轨迹才能同时看到前后两次连接结果。
        if diagnosticLines.count > 40 { diagnosticLines.removeFirst(diagnosticLines.count - 40) }
    }

    private func fail(_ message: String, reconnect: Bool = false) {
        trace("ERROR \(message)")
        if !reconnect { autoConnection.recordFailure() }
        closeConnection()
        errorMessage = message
        // 有连接时保留 disconnecting，直到系统确认释放；错误单独可见。
        if peripheral == nil { phase = .failed(message); scheduleReconnect() }
        else { reconnectAfterClose = reconnect }
    }

    private func cancelDeadline() {
        deadlineGeneration &+= 1
        deadline?.invalidate()
        deadline = nil
    }

    private func scheduleDeadline(seconds: TimeInterval, action: @escaping @MainActor (BowersWilkinsController) -> Void) {
        cancelDeadline()
        let generation = deadlineGeneration
        deadline = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.deadlineGeneration == generation else { return }
                action(self)
            }
        }
    }

    private func armDeadline(seconds: TimeInterval, message: String) {
        scheduleDeadline(seconds: seconds) { $0.fail(message, reconnect: true) }
    }

    private func enqueueReads() {
        // 没有核实线值的型号只读取电量与充电状态，不猜 ANC 的数字含义。
        let reads = noiseProfile == .unverified ? BWRPCatalog.batteryReads : BWRPCatalog.primaryReads
        queue = reads.map { Request(command: $0, payload: nil, purpose: .refresh) }
        sendNext()
    }

    private func sendNext() {
        guard routeAuthorized else { return }
        guard current == nil else { return }
        guard !queue.isEmpty else {
            busy = false
            if !bindingConfirmed, state.battery != nil,
               peripheral != nil, boundOutputUID != nil {
                autoConnection.confirmedConnection()
                bindingConfirmed = true
                trace("BLE IDENTITY CONFIRMED; INITIAL READS COMPLETE")
            }
            return
        }
        guard let peripheral, let characteristic = requestCharacteristic, phase == .ready || phase == .verifying else {
            fail("耳机控制通道未就绪"); return
        }
        let next = queue.removeFirst()
        do {
            guard let boundOutputUID else { throw AudioFailure("耳机输出绑定已丢失") }
            try HeadphoneRouteGuard.check(boundOutputUID)
            let packet = try BWRPC.request(next.command, payload: next.payload)
            guard packet.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
                throw AudioFailure("耳机单次写入长度不足")
            }
            busy = true
            current = next; writeAcknowledged = false; reply = nil
            trace("TX \(next.command.key) [\(packet.count)B] \(packet.hexString)")
            peripheral.writeValue(packet, for: characteristic, type: .withResponse)
            armDeadline(seconds: 6, message: "耳机命令 \(next.command.key) 超时，控制通道已断开")
        } catch { fail(error.localizedDescription) }
    }

    private func finishTransactionIfReady() {
        guard writeAcknowledged, let reply, let request = current else { return }
        cancelDeadline()
        do {
            switch request.purpose {
            case .identify:
                guard reply.succeeded else { throw AudioFailure("耳机拒绝硬件身份查询") }
                guard let reported = reply.payload?.stringValue else {
                    throw AudioFailure("耳机身份响应不是可验证的地址")
                }
                guard let boundOutputUID else {
                    throw AudioFailure("当前系统输出已改变，无法验证耳机身份")
                }
                let matches = HeadphonePhysicalIdentity.matchesBowersWilkinsControl(
                    reported: reported,
                    outputUID: boundOutputUID,
                    advertisedName: selectedCandidateName,
                    outputName: observedOutput?.name
                )
                guard matches else {
                    // 只记录地址，不发送任何控制命令；下一次扫描会重新选择广播并再次严格核验。
                    let expected = HeadphonePhysicalIdentity.addressInOutputUID(boundOutputUID) ?? "invalid"
                    trace("PHYSICAL ADDRESS MISMATCH reported=\(reported) expected=\(expected)")
                    throw AudioFailure("耳机硬件身份与当前音频输出不匹配，已停止连接")
                }
                identityVerified = true
                trace("PHYSICAL ADDRESS VERIFIED")
                phase = .ready
                let reads = noiseProfile == .unverified ? BWRPCatalog.batteryReads : BWRPCatalog.primaryReads
                queue = reads.map { Request(command: $0, payload: nil, purpose: .refresh) }
            case .refresh:
                if try !state.applyRefresh(reply, profile: noiseProfile) {
                    if reply.command == BWRPCatalog.ancGet {
                        errorMessage = "该耳机未确认降噪读取能力（错误 \(reply.errorCode)）"
                        trace("ANC CAPABILITY NOT CONFIRMED")
                    } else {
                        trace("CHARGING CAPABILITY NOT CONFIRMED")
                    }
                }
            case .setNoise(let desired):
                guard reply.succeeded else { throw AudioFailure("耳机拒绝噪声模式设置（错误 \(reply.errorCode)）") }
                // SET 的 RPC 确认之后才 GET；GATT 写入成功不代表耳机已应用设置。
                queue.insert(Request(command: BWRPCatalog.ancGet, payload: nil, purpose: .confirmNoise(desired)), at: 0)
            case .confirmNoise(let desired):
                try state.apply(reply, profile: noiseProfile)
                guard state.noiseMode == desired else { throw AudioFailure("耳机回读与请求不一致，未确认降噪切换成功") }
                pendingNoiseMode = nil
            }
            current = nil; self.reply = nil; writeAcknowledged = false
            sendNext()
        } catch {
            // 身份查询阶段尚未发送控制命令。失败的可能是过早选中的旧广播，
            // 因此重新扫描一次，不能把整个自动连接永久锁死。
            fail(error.localizedDescription, reconnect: request.purpose.isIdentityCheck)
        }
    }

    private func finishDiscovery() {
        guard pendingServices.isEmpty else { return }
        guard let peripheral, let requestCharacteristic, let responseCharacteristic else {
            fail("耳机缺少所需 RPC 特征，未启用任何控制"); return
        }
        guard requestCharacteristic.properties.contains(.write), responseCharacteristic.properties.contains(.notify) else {
            fail("当前仅支持带 GATT 响应的写入和通知特征"); return
        }
        pendingSubscriptions = [responseCharacteristic.uuid]
        if let eventCharacteristic {
            guard eventCharacteristic.properties.contains(.notify) else { fail("耳机事件特征不支持通知"); return }
            pendingSubscriptions.insert(eventCharacteristic.uuid)
            peripheral.setNotifyValue(true, for: eventCharacteristic)
        }
        peripheral.setNotifyValue(true, for: responseCharacteristic)
    }
}

extension BowersWilkinsController: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central else { return }
        let previous = previousRadioState
        previousRadioState = central.state
        if central.state == .poweredOn {
            if previous != .unknown && previous != .poweredOn {
                autoConnection.radioOrWakeRecovered()
                errorMessage = nil
            }
            if phase == .starting { beginScan(central) }
            else { startAutomaticallyIfNeeded() }
            return
        }
        if central.state == .unknown { return }
        if observedOutput != nil { fail("蓝牙不可用或权限被拒绝") }
        else { closeConnection() }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.central === central, phase == .scanning else { return }
        // 模型广播和 LE_BWHP 是同一发现集合，不按 RSSI 或旧 UUID 选择后备设备。
        // 广播未携带本地名时使用 CoreBluetooth 为该真实外设提供的名称。
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name: String
        if let advertised, !advertised.isEmpty { name = advertised }
        else if let cachedName = peripheral.name, !cachedName.isEmpty { name = cachedName }
        else { return }
        guard HeadphoneFamily.isBowersWilkinsAdvertisement(name) else { return }
        discovered[peripheral.identifier] = peripheral
        if !candidates.contains(where: { $0.id == peripheral.identifier }) {
            candidates.append(HeadphoneCandidate(id: peripheral.identifier, name: name))
        }
        if let started = scanStartedAt, Date().timeIntervalSince(started) >= 2 {
            evaluateAutomaticSelection()
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.central === central, self.peripheral === peripheral, phase == .connecting else { return }
        phase = .discovering
        peripheral.discoverServices(nil)
        armDeadline(seconds: 15, message: "验证耳机 RPC 服务超时")
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.central === central, self.peripheral === peripheral else { return }
        let requested = closingConnection
        cancelDeadline(); cancelSelection()
        peripheral.delegate = nil; self.peripheral = nil
        closingConnection = false
        clearReadings(); boundOutputUID = nil
        if requested {
            phase = .idle
            if reconnectAfterClose { reconnectAfterClose = false; scheduleReconnect() }
            else { startAutomaticallyIfNeeded() }
        } else {
            if let error { errorMessage = "连接失败：\(error.localizedDescription)" }
            else { errorMessage = "系统未能建立耳机控制通道" }
            phase = .failed("耳机连接失败")
            scheduleReconnect()
        }
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.central === central, self.peripheral === peripheral else { return }
        let requested = closingConnection
        cancelDeadline(); cancelSelection()
        peripheral.delegate = nil; self.peripheral = nil
        closingConnection = false
        clearReadings(); boundOutputUID = nil
        if let error { errorMessage = error.localizedDescription }
        if let errorMessage { phase = .failed(errorMessage) }
        else { phase = .idle }
        if requested {
            if reconnectAfterClose { reconnectAfterClose = false; scheduleReconnect() }
            else { startAutomaticallyIfNeeded() }
        } else { scheduleReconnect() }
    }

}

extension BowersWilkinsController: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral, phase == .discovering else { return }
        if let error { fail(error.localizedDescription); return }
        guard let services = peripheral.services, !services.isEmpty else { fail("耳机没有公开 GATT 服务"); return }
        pendingServices = Set(services.map(ObjectIdentifier.init))
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral, phase == .discovering,
              pendingServices.contains(ObjectIdentifier(service)) else { return }
        if let error { fail(error.localizedDescription); return }
        guard let characteristics = service.characteristics else { fail("无法读取耳机特征"); return }
        for characteristic in characteristics {
            switch characteristic.uuid {
            case CBUUID(string: BWRPC.requestUUID): requestCharacteristic = characteristic
            case CBUUID(string: BWRPC.responseUUID): responseCharacteristic = characteristic
            case CBUUID(string: BWRPC.notificationUUID): eventCharacteristic = characteristic
            default: break
            }
        }
        pendingServices.remove(ObjectIdentifier(service))
        finishDiscovery()
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, phase == .discovering,
              pendingSubscriptions.contains(characteristic.uuid) else { return }
        if let error { fail(error.localizedDescription); return }
        guard characteristic.isNotifying else { fail("未能启用耳机响应通知"); return }
        pendingSubscriptions.remove(characteristic.uuid)
        if pendingSubscriptions.isEmpty {
            cancelDeadline()
            phase = .verifying
            busy = true
            queue = [Request(command: BWRPCatalog.addressGet, payload: nil, purpose: .identify)]
            sendNext()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, phase == .ready || phase == .verifying,
              characteristic === requestCharacteristic, current != nil else { return }
        if let error { fail(error.localizedDescription); return }
        writeAcknowledged = true
        finishTransactionIfReady()
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, phase == .ready || phase == .verifying,
              characteristic === responseCharacteristic || characteristic === eventCharacteristic else { return }
        if let error { fail(error.localizedDescription); return }
        guard let data = characteristic.value else { fail("耳机通知没有数据"); return }
        trace("RX [\(data.count)B] \(Data(data.prefix(64)).hexString)")
        do {
            let message = try BWRPC.decode(data)
            if message.kind == .notification {
                if identityVerified { try state.apply(message, profile: noiseProfile) }
            } else if let current, current.command == message.command {
                reply = message
                finishTransactionIfReady()
            }
        } catch { fail(error.localizedDescription) }
    }
}
