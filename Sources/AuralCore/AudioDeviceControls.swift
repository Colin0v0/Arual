import AudioToolbox
import CoreAudio
import Foundation

/// 输入与输出共用展示字段，但系统选择与硬件属性始终由各自方向的接口处理。
public protocol AudioDeviceDescriptor: Identifiable where ID == AudioDeviceID {
    var id: AudioDeviceID { get }
    var uid: String { get }
    var name: String { get }
    var symbol: String { get }
    var direction: AudioDeviceDirection { get }
}

/// 输入与输出的属性作用域显式区分，不通过失败后换 scope 的方式试探设备。
public enum AudioDeviceDirection: CaseIterable, Hashable {
    case output, input
    public var title: String { self == .output ? "输出" : "麦克风" }
    public var symbol: String { self == .output ? "speaker.wave.2" : "mic" }
    public var scope: AudioObjectPropertyScope {
        self == .output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
    }
}

public struct AudioDeviceVolume: Equatable, Codable {
    /// nil 表示设备没有公开此音量属性，不能将它伪装成 50% 或 100%。
    public let scalar: Float?
    public let writable: Bool
    public init(scalar: Float?, writable: Bool) { self.scalar = scalar; self.writable = writable }
}

public struct AudioDeviceMute: Equatable, Codable {
    /// 不支持静音与“未静音”是两种状态，不用将音量写成零来冒充硬件静音。
    public let muted: Bool?
    public let writable: Bool
    public init(muted: Bool?, writable: Bool) { self.muted = muted; self.writable = writable }
}

/// 设备读取失败是显式错误；不影响其他设备的真实控制，也不制造默认读数。
public enum AudioDeviceControlState: Equatable, Codable {
    case available(volume: AudioDeviceVolume, mute: AudioDeviceMute)
    case failed(message: String)
}

/// 每个方向只有一条 HAL 路径。读取属性不打开音频流，也不申请麦克风录音权限。
public enum AudioDeviceControls {
    static func volumeAddress(_ direction: AudioDeviceDirection) -> AudioObjectPropertyAddress {
        HAL.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: direction.scope)
    }

    static func muteAddress(_ direction: AudioDeviceDirection) -> AudioObjectPropertyAddress {
        HAL.address(kAudioDevicePropertyMute, scope: direction.scope)
    }

    static func readControls(for ids: [AudioDeviceID],
                             readVolume: (AudioDeviceID) throws -> AudioDeviceVolume,
                             readMute: (AudioDeviceID) throws -> AudioDeviceMute) -> [AudioDeviceID: AudioDeviceControlState] {
        var controls: [AudioDeviceID: AudioDeviceControlState] = [:]
        for id in ids {
            do { controls[id] = .available(volume: try readVolume(id), mute: try readMute(id)) }
            catch { controls[id] = .failed(message: error.localizedDescription) }
        }
        return controls
    }

    public static func volume(of device: AudioDeviceID, direction: AudioDeviceDirection) throws -> AudioDeviceVolume {
        var address = volumeAddress(direction)
        guard AudioObjectHasProperty(device, &address) else { return AudioDeviceVolume(scalar: nil, writable: false) }
        var settable: DarwinBoolean = false
        try HAL.check(AudioObjectIsPropertySettable(device, &address, &settable), "查询设备音量能力")
        let value = try HAL.read(device, address, initial: Float(0))
        guard value.isFinite, (0...1).contains(value) else { throw AudioFailure("设备返回了无效音量") }
        return AudioDeviceVolume(scalar: value, writable: settable.boolValue)
    }

    public static func mute(of device: AudioDeviceID, direction: AudioDeviceDirection) throws -> AudioDeviceMute {
        var address = muteAddress(direction)
        guard AudioObjectHasProperty(device, &address) else { return AudioDeviceMute(muted: nil, writable: false) }
        var settable: DarwinBoolean = false
        try HAL.check(AudioObjectIsPropertySettable(device, &address, &settable), "查询设备静音能力")
        let value = try HAL.read(device, address, initial: UInt32(0))
        guard value <= 1 else { throw AudioFailure("设备返回了无效静音状态") }
        return AudioDeviceMute(muted: value == 1, writable: settable.boolValue)
    }

    public static func setVolume(_ value: Float, on device: AudioDeviceID, direction: AudioDeviceDirection) throws {
        guard value.isFinite, (0...1).contains(value) else { throw AudioFailure("音量必须在 0～100% 之间") }
        guard try volume(of: device, direction: direction).writable else {
            throw AudioFailure("该设备未公开可写的\(direction.title)音量控制")
        }
        try HAL.write(device, volumeAddress(direction), value: value)
    }

    public static func setMute(_ muted: Bool, on device: AudioDeviceID, direction: AudioDeviceDirection) throws {
        guard try mute(of: device, direction: direction).writable else {
            throw AudioFailure("该设备未公开可写的\(direction.title)静音控制")
        }
        try HAL.write(device, muteAddress(direction), value: UInt32(muted ? 1 : 0))
        guard try mute(of: device, direction: direction).muted == muted else {
            throw AudioFailure("设备未确认静音变更，请刷新后检查")
        }
    }
}
