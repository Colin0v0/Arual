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

    /// 由用户在系统对话框中决定授权。完成回调是本次决定的直接结果，
    /// 不能用同一进程可能缓存的 preflight 结果替代，否则授权后可能永远等不到重启。
    public static func requestAccess(completion: @escaping @Sendable (Bool) -> Void) throws {
        guard let request = AudioCaptureAccessQuery.request else {
            throw AudioFailure("系统音频授权请求接口不可用")
        }
        // 显式要求系统展示授权提示；是否再次提示仍由 macOS 的 TCC 记录决定。
        guard let promptOption = AudioCaptureAccessQuery.promptOption else {
            throw AudioFailure("系统音频授权提示接口不可用")
        }
        let options = [promptOption: kCFBooleanTrue as CFBoolean] as CFDictionary
        request("kTCCServiceAudioCapture" as CFString, options) { granted in completion(granted) }
    }

    public static func current() -> Self {
        guard let query = AudioCaptureAccessQuery.function else { return .unavailable }
        return resolve(audio: query("kTCCServiceAudioCapture" as CFString, nil),
                       screen: query("kTCCServiceScreenCapture" as CFString, nil))
    }
}

/// macOS 尚无公开的 Process Tap 授权状态查询接口。
/// TCC SPI 限定在这里：查询不读取数据库或日志；申请仍由 macOS 弹窗让用户决定。
/// 接口不可用就明确报告错误，绝不切换后端、自动授予权限或假定成功。
private enum AudioCaptureAccessQuery {
    typealias Function = @convention(c) (CFString, CFDictionary?) -> Int
    typealias Completion = @convention(block) (Bool) -> Void
    // TCC 会在函数返回后异步调用完成块；明确标记为逃逸，避免栈上闭包失效。
    typealias Request = @convention(c) (CFString, CFDictionary?, @escaping Completion) -> Void

    // 函数指针在进程生命周期内使用，因此持有 handle，不在查询期间卸载 framework。
    static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_LOCAL | RTLD_NOW)
    static let request: Request? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(symbol, to: Request.self)
    }()
    static let function: Function? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()
    static let promptOption: CFString? = {
        guard let handle, let symbol = dlsym(handle, "kTCCAccessCheckOptionPrompt") else { return nil }
        let value = symbol.assumingMemoryBound(to: UnsafeRawPointer?.self).pointee
        guard let value else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue()
    }()
}
