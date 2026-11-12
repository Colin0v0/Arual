import CoreFoundation
import Darwin

/// 权限事实与音频活动分开保存：没有声音、全零 PCM、回调成功都不是授权证据。
public enum SystemAudioCaptureAccess: String, Equatable, Codable, Sendable {
    case authorized
    case denied
    case notDetermined
    case unavailable

    public var allowsApplicationAudio: Bool { self == .authorized }

    /// 系统可能授予“仅系统音频”或完整“屏幕与系统音频”权限，任一授权均有效。
    /// 未知返回值不能解释成用户拒绝；接口缺失也不能解释成已经授权。
    static func resolve(audio: Int?, screen: Int?) -> Self {
        guard let audio, let screen,
              (0...2).contains(audio), (0...2).contains(screen) else { return .unavailable }
        if audio == 0 || screen == 0 { return .authorized }
        if audio == 1 { return .denied }
        return .notDetermined
    }

    public static func current() -> Self {
        guard let query = AudioCaptureAccessQuery.function else { return .unavailable }
        return resolve(audio: query("kTCCServiceAudioCapture" as CFString, nil),
                       screen: query("kTCCServiceScreenCapture" as CFString, nil))
    }
}

/// macOS 尚无公开的 Process Tap 授权状态查询接口。
/// 将只读 TCC SPI 限定在这里：不申请、不修改权限，不读取 TCC 数据库或系统日志，
/// 接口不可用就明确报告 unavailable，绝不切换查询后端或假定成功。
private enum AudioCaptureAccessQuery {
    typealias Function = @convention(c) (CFString, CFDictionary?) -> Int

    // 函数指针在进程生命周期内使用，因此持有 handle，不在查询期间卸载 framework。
    static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_LOCAL | RTLD_NOW)
    static let function: Function? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()
}
