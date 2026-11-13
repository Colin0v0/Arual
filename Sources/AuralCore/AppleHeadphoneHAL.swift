import CoreAudio
import Foundation

/// 保留佩戴状态的确定程度，不能把未知的一侧当成已佩戴或单耳。
public enum AppleHeadphoneWearState: Equatable, Sendable {
    case bothEars, singleEar, notWorn, unknown
    public var isWorn: Bool? {
        switch self {
        case .bothEars, .singleEar: return true
        case .notWorn: return false
        case .unknown: return nil
        }
    }
}

public struct AppleHeadphoneSnapshot: Equatable, Sendable {
    public let noiseMode: NoiseMode
    public let supportedNoiseModes: [NoiseMode]
    public let wearState: AppleHeadphoneWearState
    public var isWorn: Bool? { wearState.isWorn }

    public init(noiseMode: NoiseMode, supportedNoiseModes: [NoiseMode],
                wearState: AppleHeadphoneWearState = .unknown) {
        self.noiseMode = noiseMode
        self.supportedNoiseModes = supportedNoiseModes
        self.wearState = wearState
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
            wearState: try wearState(deviceID: deviceID)
        )
    }

    /// 两侧都确认为入耳才开放模式控制；未知值不推测为单耳或未佩戴。
    public static func wearState(deviceID: AudioDeviceID) throws -> AppleHeadphoneWearState {
        let enabledAddress = HAL.address(0x6965_6465)
        let placementAddress = HAL.address(0x6965_7362)
        guard isSupported(deviceID: deviceID), HAL.hasProperty(deviceID, enabledAddress),
              HAL.hasProperty(deviceID, placementAddress) else { return .unknown }
        let enabled: UInt32 = try HAL.read(deviceID, enabledAddress, initial: 0)
        guard enabled == 1 else { return .unknown }
        let placement = try HAL.read(deviceID, placementAddress, initial: (UInt32(0), UInt32(0)))
        return wearState(primary: placement.0, secondary: placement.1)
    }

    static func wearState(primary: UInt32, secondary: UInt32) -> AppleHeadphoneWearState {
        guard (1...3).contains(primary), (1...3).contains(secondary) else { return .unknown }
        if primary == 1 && secondary == 1 { return .bothEars }
        if primary == 1 || secondary == 1 { return .singleEar }
        return .notWorn
    }

    /// 路由恢复仍只查询是否佩戴，不与模式控制所需的“双耳确认”混用。
    public static func isWorn(deviceID: AudioDeviceID) throws -> Bool? {
        try wearState(deviceID: deviceID).isWorn
    }
    static func wornState(primary: UInt32, secondary: UInt32) -> Bool? {
        wearState(primary: primary, secondary: secondary).isWorn
    }

    /// Apple 的 `lsms` 只声明降噪相关模式，不声明“关闭”（Allow Off）。
    ///
    /// 对公开了聆听模式的设备，关闭始终是系统提供的原始模式 1。这里不能在
    /// 当前处于其他模式时漏掉关闭，否则用户只能单方向切走，无法再切回 Off。
    /// 没有任何聆听模式能力且当前值也不是 Off 时，仍保持空列表，不凭空启用控制。
    static func supportedModes(mask: UInt32, currentRaw: UInt32) -> [NoiseMode] {
        var modes: Set<NoiseMode> = []
        if currentRaw == 1 || mask != 0 { modes.insert(.off) }
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
        guard before.wearState == .bothEars else { throw AppleHeadphoneNotWorn() }
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
