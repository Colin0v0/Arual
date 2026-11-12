import Foundation

/// 会话只有在已确认的路由上创建。测试注入等价接口，不创建真实 tap、不修改系统输出。
@MainActor
public protocol ApplicationAudioSession: AnyObject {
    var group: AudioProcessGroup { get }
    var output: AudioOutput { get }
    var mode: ApplicationAudioMode { get }
    /// 会话实际使用的捕获源与重放目标；模型据此判断是否需要因设备集合变化重建。
    var playbackRoute: ApplicationPlaybackRoute { get }
    var isActive: Bool { get }
    var isReleased: Bool { get }
    func setGain(_ value: Float) throws
    func setMuted(_ value: Bool)
    func start() throws
    func checkHealth(expectingAudio: Bool) throws
    func stop() throws
    func consumePeak() -> Float?
}

/// 路由尚未传播，或同一蓝牙设备正在改变原生 PCM 格式，都不是权限失败。
/// 调用层按截止时间等待同一目标，并按真实格式重建同一处理链。
public struct ApplicationRoutePending: Error {
    public init() {}
}
