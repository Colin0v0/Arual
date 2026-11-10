import CoreAudio
import Foundation

public struct AudioInput: AudioDeviceDescriptor, Equatable, Codable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let transport: UInt32
    public var symbol: String { "mic" }
    public var direction: AudioDeviceDirection { .input }

    public init(id: AudioDeviceID, uid: String, name: String, transport: UInt32) {
        self.id = id; self.uid = uid; self.name = name; self.transport = transport
    }
}

public struct SystemInputSnapshot: Codable, Equatable {
    public let inputs: [AudioInput]
    /// nil 表示系统没有默认输入，不擅自选用列表中的第一台设备。
    public let selectedID: AudioDeviceID?
    public let controls: [AudioDeviceID: AudioDeviceControlState]

    public init(inputs: [AudioInput], selectedID: AudioDeviceID?, controls: [AudioDeviceID: AudioDeviceControlState]) {
        self.inputs = inputs; self.selectedID = selectedID; self.controls = controls
    }
}

/// 只管理系统输入设备与硬件属性，不建立录音会话，不混入应用输出 tap。
public enum SystemInput {
    static var defaultDeviceAddress: AudioObjectPropertyAddress { HAL.address(kAudioHardwarePropertyDefaultInputDevice) }

    public static func snapshot() throws -> SystemInputSnapshot {
        let ids = try HAL.ids(HAL.system, HAL.address(kAudioHardwarePropertyDevices))
        var inputs: [AudioInput] = []
        for id in ids {
            let streams = try HAL.ids(id, HAL.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput))
            guard !streams.isEmpty else { continue }
            let uid = try HAL.string(id, kAudioDevicePropertyDeviceUID)
            guard !uid.hasPrefix("local.aural.tap.") else { continue }
            inputs.append(AudioInput(id: id, uid: uid, name: try HAL.string(id, kAudioObjectPropertyName),
                                     transport: try HAL.read(id, HAL.address(kAudioDevicePropertyTransportType), initial: UInt32(0))))
        }
        inputs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let selected: AudioDeviceID = try HAL.read(HAL.system, defaultDeviceAddress, initial: 0)
        guard selected == 0 || inputs.contains(where: { $0.id == selected }) else {
            throw AudioFailure("当前默认输入设备不可用，请刷新后检查")
        }
        let controls = AudioDeviceControls.readControls(for: inputs.map(\.id), readVolume: volume, readMute: mute)
        return SystemInputSnapshot(inputs: inputs, selectedID: selected == 0 ? nil : selected, controls: controls)
    }

    public static func volume(of device: AudioDeviceID) throws -> AudioDeviceVolume {
        try AudioDeviceControls.volume(of: device, direction: .input)
    }

    public static func mute(of device: AudioDeviceID) throws -> AudioDeviceMute {
        try AudioDeviceControls.mute(of: device, direction: .input)
    }

    public static func setVolume(_ value: Float, on device: AudioDeviceID) throws {
        try AudioDeviceControls.setVolume(value, on: device, direction: .input)
    }

    public static func setMute(_ muted: Bool, on device: AudioDeviceID) throws {
        try AudioDeviceControls.setMute(muted, on: device, direction: .input)
    }

    public static func select(_ device: AudioDeviceID) throws {
        let before = try snapshot()
        guard before.inputs.contains(where: { $0.id == device }) else { throw AudioFailure("所选麦克风已断开") }
        // 只写默认输入选择器，不能调用默认输出切换或终止应用音频会话。
        try HAL.write(HAL.system, defaultDeviceAddress, value: device)
        let actual: AudioDeviceID = try HAL.read(HAL.system, defaultDeviceAddress, initial: 0)
        guard actual == device else { throw AudioFailure("系统未确认麦克风切换，请刷新后检查") }
    }
}
