import CoreAudio
import Foundation

public struct AppleHeadphoneSnapshot: Equatable, Sendable {
    public let noiseMode: NoiseMode
    public let supportedNoiseModes: [NoiseMode]
    public let isWorn: Bool?

    public init(noiseMode: NoiseMode, supportedNoiseModes: [NoiseMode], isWorn: Bool? = nil) {
        self.noiseMode = noiseMode
        self.supportedNoiseModes = supportedNoiseModes
        self.isWorn = isWorn
    }
}

/// AirPods 与 Beats 不通过 BLE GATT 控制，而是由 BTAudio HAL 暴露当前聆听模式。
/// 选择器与原始线值依据 pods-control（MIT）的 HAL 实现：
/// https://github.com/raulgg/pods-control
public enum AppleHeadphoneHAL {
    /// "lstm"：当前蓝牙聆听模式。
    private static let listeningModeSelector: AudioObjectPropertySelector = 0x6C73_746D
    /// "lsms"：设备公开的聆听模式能力位图。
    private static let listeningModeSupportSelector: AudioObjectPropertySelector = 0x6C73_6D73

    private static let rawModes: [UInt32: NoiseMode] = [
        1: .off,
        2: .cancellation,
        3: .transparency,
        4: .adaptive,
    ]

    private static func listeningModeAddress() -> AudioObjectPropertyAddress {
        HAL.address(listeningModeSelector)
    }

    /// 只检查设备自己是否公开这两项 HAL 属性，不按设备名称猜测 Apple 型号。
    public static func isSupported(deviceID: AudioDeviceID) -> Bool {
        HAL.hasProperty(deviceID, listeningModeAddress())
            && HAL.hasProperty(deviceID, HAL.address(listeningModeSupportSelector))
    }

    public static func snapshot(on deviceID: AudioDeviceID) throws -> AppleHeadphoneSnapshot {
        guard isSupported(deviceID: deviceID) else {
            throw AudioFailure("当前设备没有公开 Apple 聆听模式控制")
        }
        let currentRaw: UInt32 = try HAL.read(deviceID, listeningModeAddress(), initial: 0)
        let supportMask: UInt32 = try HAL.read(deviceID, HAL.address(listeningModeSupportSelector), initial: 0)
        guard let current = rawModes[currentRaw] else {
            throw AudioFailure("Apple 耳机返回了未知聆听模式 \(currentRaw)")
        }
        return AppleHeadphoneSnapshot(
            noiseMode: current,
            supportedNoiseModes: supportedModes(mask: supportMask, currentRaw: currentRaw),
            isWorn: try isWorn(deviceID: deviceID)
        )
    }

    /// BTAudio HAL 的 iede/iesb 为运行时属性：未公开或关闭入耳检测时返回未知，不猜测佩戴状态。
    /// 只判断是否至少一只在耳，左右主副顺序不影响结果；属性依据 pods-control 的只读实现。
    public static func isWorn(deviceID: AudioDeviceID) throws -> Bool? {
        let enabledAddress = HAL.address(0x6965_6465)
        let placementAddress = HAL.address(0x6965_7362)
        guard isSupported(deviceID: deviceID), HAL.hasProperty(deviceID, enabledAddress),
              HAL.hasProperty(deviceID, placementAddress) else { return nil }
        let enabled: UInt32 = try HAL.read(deviceID, enabledAddress, initial: 0)
        guard enabled == 1 else { return nil }
        let placement = try HAL.read(deviceID, placementAddress, initial: (UInt32(0), UInt32(0)))
        return wornState(primary: placement.0, secondary: placement.1)
    }

    static func wornState(primary: UInt32, secondary: UInt32) -> Bool? {
        guard (1...3).contains(primary), (1...3).contains(secondary) else { return nil }
        return primary == 1 || secondary == 1
    }

    /// 能力位图不声明“关闭”模式；只有设备当前确实处于关闭时才把关闭加入可选项。
    static func supportedModes(mask: UInt32, currentRaw: UInt32) -> [NoiseMode] {
        var modes: Set<NoiseMode> = []
        if currentRaw == 1 { modes.insert(.off) }
        if mask & 0b001 != 0 { modes.insert(.cancellation) }
        if mask & 0b010 != 0 { modes.insert(.transparency) }
        if mask & 0b100 != 0 { modes.insert(.adaptive) }
        return [.off, .cancellation, .transparency, .adaptive].filter { modes.contains($0) }
    }

    /// 设备 ID 可能在蓝牙重连后被复用，每次操作都同时核对 UID、存活状态及蓝牙连接。
    public static func validateControlTarget(_ output: AudioOutput) throws {
        guard try HAL.string(output.id, kAudioDevicePropertyDeviceUID) == output.uid,
              try HAL.read(output.id, HAL.address(kAudioDevicePropertyDeviceIsAlive), initial: UInt32(0)) != 0 else {
            throw AudioFailure("Apple 耳机身份已改变或设备已断开")
        }
        try HeadphoneConnectionGuard.check(output.uid)
    }

    /// 只提交一次写入。异步读回和取消由控制器完成，不在后台留一条不可取消的 sleep/write 链路。
    public static func requestNoiseMode(_ mode: NoiseMode, output: AudioOutput) throws {
        let before = try snapshot(on: output.id)
        guard before.isWorn != false else { throw AppleHeadphoneNotWorn() }
        guard before.supportedNoiseModes.contains(mode) else {
            throw AudioFailure("Apple 耳机未公开“\(mode.title)”聆听模式")
        }
        guard let rawTarget = rawModes.first(where: { $0.value == mode })?.key else {
            throw AudioFailure("Apple 耳机没有该聆听模式的写入映射")
        }
        guard try HAL.isSettable(output.id, listeningModeAddress()) else {
            throw AudioFailure("Apple 耳机聆听模式当前不可写")
        }
        try validateControlTarget(output)
        try HAL.write(output.id, listeningModeAddress(), value: rawTarget)
    }
}

/// 明确的未佩戴状态不是连接失败，禁止在这个状态下继续发 SET。
public struct AppleHeadphoneNotWorn: Error {
    public init() {}
}
