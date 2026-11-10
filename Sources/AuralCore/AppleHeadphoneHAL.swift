import CoreAudio
import Foundation

public struct AppleHeadphoneSnapshot: Equatable, Sendable {
    public let noiseMode: NoiseMode
    public let supportedNoiseModes: [NoiseMode]

    public init(noiseMode: NoiseMode, supportedNoiseModes: [NoiseMode]) {
        self.noiseMode = noiseMode
        self.supportedNoiseModes = supportedNoiseModes
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
            supportedNoiseModes: supportedModes(mask: supportMask, currentRaw: currentRaw)
        )
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

    public static func setNoiseMode(_ mode: NoiseMode, on deviceID: AudioDeviceID) throws -> AppleHeadphoneSnapshot {
        let before = try snapshot(on: deviceID)
        guard before.supportedNoiseModes.contains(mode) else {
            throw AudioFailure("Apple 耳机未公开“\(mode.title)”聆听模式")
        }
        guard let rawTarget = rawModes.first(where: { $0.value == mode })?.key else {
            throw AudioFailure("Apple 耳机没有该聆听模式的写入映射")
        }
        guard try HAL.isSettable(deviceID, listeningModeAddress()) else {
            throw AudioFailure("Apple 耳机聆听模式当前不可写")
        }

        try HAL.write(deviceID, listeningModeAddress(), value: rawTarget)
        // HAL 会先接受写入，再由系统向耳机确认；必须等待回读匹配后才宣告成功。
        for _ in 0..<16 {
            Thread.sleep(forTimeInterval: 0.05)
            let observed: UInt32 = try HAL.read(deviceID, listeningModeAddress(), initial: 0)
            if rawModes[observed] == mode {
                return try snapshot(on: deviceID)
            }
        }
        throw AudioFailure("Apple 耳机没有确认“\(mode.title)”切换")
    }
}
