// Bose RFCOMM transport facts are based on bosectl (MIT), Copyright (c) 2026 Aaron Bockelie.
// Aural owns the connection lifecycle and bounds every failure path to this device.
import Foundation
import IOBluetooth

enum BoseRFCOMMStatus: Equatable {
    case idle
    case connecting
    case connected
    case failed(String, retryable: Bool = false)
}

/// 控制器通过此接口测试真实生命周期分支；生产环境只有 RFCOMM 这一条传输路径。
@MainActor
protocol BoseControlTransport: AnyObject {
    var onStatusChange: ((BoseRFCOMMStatus) -> Void)? { get set }
    var onData: ((Data) -> Void)? { get set }
    func connect(address: String, outputUID: String, endpoint: BoseControlEndpoint)
    func disconnect()
    @discardableResult func send(_ data: Data) -> IOReturn
}

/// 按型号选择已知控制端点：Ultra 固定通道 2，prince/duran 只认其 SPP 服务记录。
/// 不探测其他通道，也不在失败后改用另一端点。
///
/// 这里只管理控制通道；关闭它不会断开蓝牙音频连接，也不会切换系统输出。
@MainActor
final class BoseRFCOMMTransport: NSObject, BoseControlTransport {
    var onStatusChange: ((BoseRFCOMMStatus) -> Void)?
    var onData: ((Data) -> Void)?

    private static let controlChannelID: BluetoothRFCOMMChannelID = 2
    private static var serialPortUUID: IOBluetoothSDPUUID { IOBluetoothSDPUUID(uuid16: 0x1101) }

    private(set) var status: BoseRFCOMMStatus = .idle
    private var boundOutputUID: String?
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var openTimeoutTask: Task<Void, Never>?
    private var generation = 0
    private var requestedDisconnect = false

    deinit {
        // 即使宿主未显式 shutdown，也不能遗留控制通道；绝不关闭蓝牙音频的基带连接。
        openTimeoutTask?.cancel()
        channel?.setDelegate(nil)
        channel?.close()
    }

    func connect(address: String, outputUID: String, endpoint: BoseControlEndpoint) {
        disconnect(notify: false)
        generation &+= 1
        let expectedGeneration = generation
        requestedDisconnect = false
        boundOutputUID = outputUID

        do {
            try HeadphoneConnectionGuard.check(outputUID)
        } catch {
            fail(error.localizedDescription)
            return
        }

        guard let device = IOBluetoothDevice(addressString: address) else {
            fail("无效的蓝牙设备地址")
            return
        }
        self.device = device
        updateStatus(.connecting)
        scheduleOpenTimeout(generation: expectedGeneration)

        switch endpoint {
        case .ultraChannel2:
            openControlChannel(on: device, channelID: Self.controlChannelID)
        case .serialPortService:
            // SPP 是 prince/duran 明确记录的入口，而非通道 2 失败后的替代链。
            let result = device.performSDPQuery(self, uuids: [Self.serialPortUUID])
            guard result == kIOReturnSuccess else {
                fail("Bose 控制服务查询失败（\(result)）", retryable: true)
                return
            }
        }
    }

    func disconnect() {
        disconnect(notify: true)
    }

    @discardableResult
    func send(_ data: Data) -> IOReturn {
        do {
            guard let boundOutputUID else { throw AudioFailure("耳机传输没有绑定系统输出") }
            try HeadphoneConnectionGuard.check(boundOutputUID)
        } catch {
            fail(error.localizedDescription)
            return kIOReturnNotPermitted
        }
        guard status == .connected, let channel else {
            return kIOReturnNotOpen
        }
        guard data.count <= Int(UInt16.max) else {
            return kIOReturnMessageTooLarge
        }

        var bytes = [UInt8](data)
        let result = bytes.withUnsafeMutableBufferPointer { buffer -> IOReturn in
            guard let baseAddress = buffer.baseAddress else { return kIOReturnNoMemory }
            return channel.writeSync(baseAddress, length: UInt16(buffer.count))
        }
        if result != kIOReturnSuccess {
            fail("Bose 控制命令发送失败（\(result)）", retryable: true)
        }
        return result
    }

    private func disconnect(notify: Bool) {
        requestedDisconnect = true
        generation &+= 1
        openTimeoutTask?.cancel()
        openTimeoutTask = nil

        let oldChannel = channel
        channel = nil
        oldChannel?.setDelegate(nil)
        oldChannel?.close()
        device = nil
        boundOutputUID = nil

        if notify {
            updateStatus(.idle)
        } else {
            status = .idle
        }
    }

    private func scheduleOpenTimeout(generation expectedGeneration: Int) {
        openTimeoutTask?.cancel()
        openTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self,
                  !Task.isCancelled,
                  self.generation == expectedGeneration,
                  self.status == .connecting else { return }
            self.fail("Bose 控制通道连接超时", retryable: true)
        }
    }

    private func openControlChannel(on device: IOBluetoothDevice, channelID: BluetoothRFCOMMChannelID) {
        var openedChannel: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(
            &openedChannel,
            withChannelID: channelID,
            delegate: self
        )
        guard result == kIOReturnSuccess else {
            fail("无法打开 Bose RFCOMM 控制通道（\(result)）", retryable: true)
            return
        }
        channel = openedChannel
    }

    private func handleSDPResult(device queried: IOBluetoothDevice?, result: IOReturn) {
        guard status == .connecting, channel == nil, let device, queried === device else { return }
        guard result == kIOReturnSuccess,
              let record = device.getServiceRecord(for: Self.serialPortUUID) else {
            fail("Bose 未公开该型号所需的 SPP 控制服务")
            return
        }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess, (1...30).contains(channelID) else {
            fail("Bose SPP 控制服务没有有效 RFCOMM 通道")
            return
        }
        openControlChannel(on: device, channelID: channelID)
    }

    private func updateStatus(_ newStatus: BoseRFCOMMStatus) {
        guard status != newStatus else { return }
        status = newStatus
        onStatusChange?(newStatus)
    }

    private func fail(_ message: String, retryable: Bool = false) {
        guard !requestedDisconnect else { return }
        generation &+= 1
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        let oldChannel = channel
        channel = nil
        oldChannel?.setDelegate(nil)
        oldChannel?.close()
        device = nil
        updateStatus(.failed(message, retryable: retryable))
    }

    private func handleOpen(channel openedChannel: IOBluetoothRFCOMMChannel?,
                            error: IOReturn) {
        guard let openedChannel else {
            if status == .connecting { fail("Bose RFCOMM 控制通道打开失败", retryable: true) }
            return
        }
        guard status == .connecting, openedChannel === channel else {
            // 旧连接或超时后的迟到回调必须立即关闭，避免泄漏 RFCOMM session。
            openedChannel.setDelegate(nil)
            openedChannel.close()
            return
        }
        guard error == kIOReturnSuccess else {
            fail("Bose RFCOMM 控制通道打开失败（\(error)）", retryable: true)
            return
        }
        openTimeoutTask?.cancel()
        openTimeoutTask = nil
        updateStatus(.connected)
    }

    private func handleData(channel sourceChannel: IOBluetoothRFCOMMChannel?, data: Data) {
        guard status == .connected,
              let sourceChannel,
              sourceChannel === channel else { return }
        onData?(data)
    }

    private func handleClosed(channel closedChannel: IOBluetoothRFCOMMChannel?) {
        guard let closedChannel, closedChannel === channel else { return }
        channel = nil
        device = nil
        generation &+= 1
        openTimeoutTask?.cancel()
        openTimeoutTask = nil

        if requestedDisconnect {
            updateStatus(.idle)
        } else {
            updateStatus(.failed("Bose 控制通道已断开", retryable: true))
        }
    }
}

extension BoseRFCOMMTransport: IOBluetoothRFCOMMChannelDelegate {
    @objc nonisolated func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        Task { @MainActor [weak self] in self?.handleSDPResult(device: device, result: status) }
    }

    nonisolated func rfcommChannelOpenComplete(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        status error: IOReturn
    ) {
        Task { @MainActor [weak self] in
            self?.handleOpen(channel: rfcommChannel, error: error)
        }
    }

    nonisolated func rfcommChannelData(
        _ rfcommChannel: IOBluetoothRFCOMMChannel!,
        data dataPointer: UnsafeMutableRawPointer!,
        length dataLength: Int
    ) {
        guard let dataPointer, dataLength > 0 else { return }
        let data = Data(bytes: dataPointer, count: dataLength)
        Task { @MainActor [weak self] in
            self?.handleData(channel: rfcommChannel, data: data)
        }
    }

    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        Task { @MainActor [weak self] in
            self?.handleClosed(channel: rfcommChannel)
        }
    }
}
