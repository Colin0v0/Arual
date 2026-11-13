import AudioToolbox
import CoreAudio
import Foundation

public struct AudioFailure: LocalizedError {
    public let message: String
    public let status: OSStatus?
    public init(_ message: String, status: OSStatus? = nil) {
        self.message = message
        self.status = status
    }
    public var errorDescription: String? { message }
}

/// HAL 枚举尚未收敛：列表仍包含已经失效的对象，不能据此确认设备消失或切换失败。
public struct AudioSnapshotPending: LocalizedError {
    public let failure: AudioFailure
    public init(_ failure: AudioFailure) { self.failure = failure }
    public var errorDescription: String? { failure.localizedDescription }
}

/// HAL 访问集中在一处；失败直接抛出，不尝试其他设备、通道或音量后端。
public enum HAL {
    public static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let serverRestartedStatus = OSStatus(-308)
    /// Core Audio 的 `who?`：列表给出对象后，对象在逐项读取前已经被系统销毁或替换。
    public static let badObjectStatus = OSStatus(0x77686F3F)

    public static func address(_ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                               element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    public static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw AudioFailure("\(operation)失败（Core Audio \(status)）", status: status)
        }
    }

    public static func hasProperty(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    public static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> Bool {
        var address = address
        var settable = DarwinBoolean(false)
        try check(AudioObjectIsPropertySettable(object, &address, &settable), "查询音频属性写入能力")
        return settable.boolValue
    }

    /// HAL 服务重启时只重试同一个只读请求；持续失败或真实属性错误仍原样抛出。
    static func retryAfterServerRestart<T>(_ operation: () throws -> T) throws -> T {
        for attempt in 0..<4 {
            do {
                return try operation()
            } catch let failure as AudioFailure where failure.status == serverRestartedStatus {
                guard attempt < 3 else { throw failure }
                // 服务重启通常只需几十毫秒；短暂等待后再读同一对象和同一属性。
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
        throw AudioFailure("Core Audio 服务未恢复", status: serverRestartedStatus)
    }

    public static func read<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T) throws -> T {
        try retryAfterServerRestart {
            var address = address
            var value = initial
            var size = UInt32(MemoryLayout<T>.size)
            let status = withUnsafeMutablePointer(to: &value) {
                AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
            }
            try check(status, "读取音频属性")
            guard size == MemoryLayout<T>.size else { throw AudioFailure("音频属性大小不符合预期") }
            return value
        }
    }

    public static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        try retryAfterServerRestart {
            var address = address(selector)
            var value: CFString = "" as CFString
            var size = UInt32(MemoryLayout<CFString>.size)
            let status = withUnsafeMutablePointer(to: &value) {
                AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
            }
            try check(status, "读取音频名称")
            return value as String
        }
    }

    public static func ids(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> [AudioObjectID] {
        try retryAfterServerRestart {
            var address = address
            var size: UInt32 = 0
            try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "查询音频对象列表")
            guard size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else {
                throw AudioFailure("音频对象列表大小不合法")
            }
            if size == 0 { return [] }
            var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            let capacity = size
            let status = result.withUnsafeMutableBytes {
                AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
            }
            try check(status, "读取音频对象列表")
            guard size <= capacity else { throw AudioFailure("设备列表读取期间发生变化，请刷新") }
            return Array(result.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
        }
    }

    public static func write<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, value: T) throws {
        var address = address
        var value = value
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
        try check(status, "写入音频属性")
    }
}

public struct AudioOutput: AudioDeviceDescriptor, Equatable, Codable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let transport: UInt32

    public init(id: AudioDeviceID, uid: String, name: String, transport: UInt32) {
        self.id = id; self.uid = uid; self.name = name; self.transport = transport
    }

    public var direction: AudioDeviceDirection { .output }

    public var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
    public var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeUSB: return "cable.connector"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        default: return "speaker.wave.2"
        }
    }
}

public struct SystemAudioSnapshot: Codable, Equatable {
    public let outputs: [AudioOutput]
    public let selectedID: AudioDeviceID
    public let controls: [AudioDeviceID: AudioDeviceControlState]

    public init(outputs: [AudioOutput], selectedID: AudioDeviceID, controls: [AudioDeviceID: AudioDeviceControlState]) {
        self.outputs = outputs; self.selectedID = selectedID; self.controls = controls
    }
}

public enum SystemAudio {
    public static func selectedOutputUID() throws -> String {
        let selected: AudioDeviceID = try HAL.read(HAL.system, HAL.address(kAudioHardwarePropertyDefaultOutputDevice), initial: 0)
        guard selected != 0 else { throw AudioFailure("当前没有系统默认输出") }
        return try HAL.string(selected, kAudioDevicePropertyDeviceUID)
    }

    /// 当前默认输出是否直接等于目标，或是否为包含目标成员的真实聚合设备。
    /// 多设备输出时默认 UID 是聚合设备，不能因此误判耳机已经不再是当前路由。
    public static func selectedRouteContains(_ outputUID: String) throws -> Bool {
        let selected: AudioDeviceID = try HAL.read(HAL.system, HAL.address(kAudioHardwarePropertyDefaultOutputDevice), initial: 0)
        guard selected != 0 else { throw AudioFailure("当前没有系统默认输出") }
        let selectedUID = try HAL.string(selected, kAudioDevicePropertyDeviceUID)
        if selectedUID == outputUID {
            return try HAL.read(selected, HAL.address(kAudioDevicePropertyDeviceIsAlive), initial: UInt32(0)) != 0
        }
        let transport: UInt32 = try HAL.read(selected, HAL.address(kAudioDevicePropertyTransportType), initial: 0)
        guard transport == kAudioDeviceTransportTypeAggregate else { return false }
        let composition: CFDictionary = try HAL.read(selected,
            HAL.address(kAudioAggregateDevicePropertyComposition), initial: [:] as CFDictionary)
        let active = try readActiveOutputUIDs(
            readActiveIDs: { try HAL.ids(selected, HAL.address(kAudioAggregateDevicePropertyActiveSubDeviceList)) },
            readUID: { try HAL.string($0, kAudioDevicePropertyDeviceUID) }
        )
        return activeAggregateRouteContains(outputUID, composition: composition, activeUIDs: active)
    }

    /// 配置里仍留着一个成员，不代表 HAL 已经在使用它；所有厂商的控制授权都要求真实激活。
    static func activeAggregateRouteContains(_ outputUID: String, composition: CFDictionary, activeUIDs: [String]) -> Bool {
        aggregateCompositionContains(outputUID, composition: composition) && activeUIDs.contains(outputUID)
    }

    static func aggregateCompositionContains(_ outputUID: String, composition: CFDictionary) -> Bool {
        guard let dictionary = composition as? [String: Any],
              let members = dictionary[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]] else {
            return false
        }
        return members.contains { ($0[kAudioSubDeviceUIDKey] as? String) == outputUID }
    }

    public static func snapshot() throws -> SystemAudioSnapshot {
        try readSettledSnapshot { try readSnapshot() }
    }

    /// 设备重连时旧 ID 可能仍留在 HAL 列表中；重新枚举整份快照，不能反复读取旧 ID。
    /// 仅对明确的失效对象短暂重试，持续失败仍向调用者报告，不返回不完整快照。
    static func readSettledSnapshot<T>(_ read: () throws -> T) throws -> T {
        for attempt in 0..<3 {
            do {
                return try read()
            } catch let pending as AudioSnapshotPending {
                guard attempt < 2 else { throw pending }
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
        preconditionFailure("快照重试次数必须大于零")
    }

    private static func readSnapshot() throws -> SystemAudioSnapshot {
        let ids = try HAL.ids(HAL.system, HAL.address(kAudioHardwarePropertyDevices))
        let outputs = try readOutputs(
            deviceIDs: ids,
            readStreams: { try HAL.ids($0, HAL.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)) },
            readUID: { try HAL.string($0, kAudioDevicePropertyDeviceUID) },
            readName: { try HAL.string($0, kAudioObjectPropertyName) },
            readTransport: { try HAL.read($0, HAL.address(kAudioDevicePropertyTransportType), initial: UInt32(0)) },
            currentDeviceIDs: { try HAL.ids(HAL.system, HAL.address(kAudioHardwarePropertyDevices)) }
        )
        let selected: AudioDeviceID = try HAL.read(HAL.system, HAL.address(kAudioHardwarePropertyDefaultOutputDevice), initial: 0)
        try requireSettledDefaultOutput(selected, outputs: outputs)
        return SystemAudioSnapshot(outputs: outputs, selectedID: selected,
                                   controls: readControls(for: outputs, readVolume: volume, readMute: mute))
    }

    /// 蓝牙连接或断开时，默认设备可能先于输出流出现在 HAL 中。
    /// 此时整份枚举只是尚未收敛，不能在设备仍处于切换窗口时锁存为永久失败。
    static func requireSettledDefaultOutput(_ selected: AudioDeviceID, outputs: [AudioOutput]) throws {
        guard selected != 0, outputs.contains(where: { $0.id == selected }) else {
            throw AudioSnapshotPending(AudioFailure("当前没有可用的默认输出设备"))
        }
    }

    /// 设备可能在系统列表与逐项读取之间重连；属性读取失败时先核对当前列表并重试一次。
    static func readOutputs(deviceIDs: [AudioDeviceID],
                            readStreams: (AudioDeviceID) throws -> [AudioObjectID],
                            readUID: (AudioDeviceID) throws -> String,
                            readName: (AudioDeviceID) throws -> String,
                            readTransport: (AudioDeviceID) throws -> UInt32,
                            currentDeviceIDs: () throws -> [AudioDeviceID]) throws -> [AudioOutput] {
        var outputs: [AudioOutput] = []
        for id in deviceIDs {
            var completed = false
            for attempt in 0..<2 where !completed {
                do {
                    let streams = try readStreams(id)
                    guard !streams.isEmpty else {
                        completed = true
                        continue
                    }
                    let uid = try readUID(id)
                    // Aural 的内部聚合设备只服务于音频回调，不应出现在用户的输出选择器中。
                    guard !uid.hasPrefix("local.aural.tap.") else {
                        completed = true
                        continue
                    }
                    outputs.append(AudioOutput(id: id, uid: uid,
                                               name: try readName(id),
                                               transport: try readTransport(id)))
                    completed = true
                } catch {
                    // 每次失败都重新核对当前设备表；对象可能在第一次重试后、第二次读取前才消失。
                    let stillPresent = try currentDeviceIDs().contains(id)
                    guard stillPresent else {
                        completed = true
                        continue
                    }
                    if attempt == 1 {
                        if let failure = error as? AudioFailure, failure.status == HAL.badObjectStatus {
                            throw AudioSnapshotPending(failure)
                        }
                        throw error
                    }
                    // 聚合设备销毁时 HAL 可能短暂保留旧对象；只对明确的 `who?` 等待一个短窗口。
                    if let failure = error as? AudioFailure, failure.status == HAL.badObjectStatus {
                        Thread.sleep(forTimeInterval: 0.03)
                    }
                }
            }
        }
        outputs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return outputs
    }

    /// 保留输出端的明确入口，底层只使用 output scope，不尝试其他通道或后端。
    static func readControls(for outputs: [AudioOutput],
                             readVolume: (AudioDeviceID) throws -> AudioDeviceVolume,
                             readMute: (AudioDeviceID) throws -> AudioDeviceMute) -> [AudioDeviceID: AudioDeviceControlState] {
        AudioDeviceControls.readControls(for: outputs.map(\.id), readVolume: readVolume, readMute: readMute)
    }

    public static func volume(of device: AudioDeviceID) throws -> AudioDeviceVolume {
        try AudioDeviceControls.volume(of: device, direction: .output)
    }

    public static func mute(of device: AudioDeviceID) throws -> AudioDeviceMute {
        try AudioDeviceControls.mute(of: device, direction: .output)
    }

    public static func setMute(_ muted: Bool, on device: AudioDeviceID) throws {
        try AudioDeviceControls.setMute(muted, on: device, direction: .output)
    }

    /// 写入本次明确选择的两条默认路由；确认由协调器后续的 HAL 观察完成，不在主线程 sleep。
    public static func requestSelection(_ device: AudioDeviceID) throws {
        let alive: UInt32 = try HAL.read(device, HAL.address(kAudioDevicePropertyDeviceIsAlive), initial: 0)
        let streams = try HAL.ids(device, HAL.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput))
        guard alive != 0, !streams.isEmpty else { throw AudioFailure("所选输出设备已断开") }
        try HAL.write(HAL.system, HAL.address(kAudioHardwarePropertyDefaultOutputDevice), value: device)
        try HAL.write(HAL.system, HAL.address(kAudioHardwarePropertyDefaultSystemOutputDevice), value: device)
    }

    public static func selectedSystemOutputID() throws -> AudioDeviceID {
        try HAL.read(HAL.system, HAL.address(kAudioHardwarePropertyDefaultSystemOutputDevice), initial: 0)
    }

    /// 同步调用者必须读回确认；交互路由使用 requestSelection 与异步阶段机。
    public static func select(_ device: AudioDeviceID) throws {
        try requestSelection(device)
        let actual: AudioDeviceID = try HAL.read(HAL.system, HAL.address(kAudioHardwarePropertyDefaultOutputDevice), initial: 0)
        guard actual == device, try selectedSystemOutputID() == device else {
            throw AudioFailure("系统未确认输出切换，请刷新后检查")
        }
    }

    public static func setVolume(_ value: Float, on device: AudioDeviceID) throws {
        try AudioDeviceControls.setVolume(value, on: device, direction: .output)
    }
}
