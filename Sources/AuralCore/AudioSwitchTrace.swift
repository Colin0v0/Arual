import OSLog

/// 只记录音频图操作的耗时区间，不记录音频、应用身份或蓝牙地址。
/// 用 Instruments 的 Points of Interest 区分 HAL 重配时间和 APP 会话重建时间。
enum AudioSwitchTrace {
    private static let signposter = OSSignposter(subsystem: "local.aural.app", category: "AudioSwitch")

    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    static func end(_ name: StaticString, _ interval: OSSignpostIntervalState) {
        signposter.endInterval(name, interval)
    }
}
