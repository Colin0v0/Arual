import AppKit
import Combine
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case chinese
    case english

    var id: String { rawValue }

    /// 跟随系统时只区分中文与其他语言；当前产品只提供中英两套文案。
    func resolved(systemLanguage: String = Locale.preferredLanguages.first ?? "en") -> AppLanguage {
        switch self {
        case .chinese, .english: return self
        case .system:
            return systemLanguage.lowercased().hasPrefix("zh") ? .chinese : .english
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// 设置只保存用户明确选择的产品项；读取失败不使用另一套业务路径。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let language = "local.aural.settings.language"
        static let appearance = "local.aural.settings.appearance"
        static let headphones = "local.aural.settings.showHeadphones"
        static let simultaneousOutput = "local.aural.settings.showSimultaneousOutput"
    }

    private let defaults: UserDefaults

    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Key.language) }
    }
    @Published var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Key.appearance)
            applyApplicationAppearance()
        }
    }
    @Published var showHeadphoneControls: Bool {
        didSet { defaults.set(showHeadphoneControls, forKey: Key.headphones) }
    }
    @Published var showSimultaneousOutput: Bool {
        didSet { defaults.set(showSimultaneousOutput, forKey: Key.simultaneousOutput) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = AppLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .system
        appearance = AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        // 耳机控制与同时输出都是可选能力，首次启动默认关闭，避免主面板主动扩展入口。
        showHeadphoneControls = defaults.object(forKey: Key.headphones) as? Bool ?? false
        showSimultaneousOutput = defaults.object(forKey: Key.simultaneousOutput) as? Bool ?? false
    }

    var resolvedLanguage: AppLanguage {
        language.resolved()
    }

    func localized(_ key: String) -> String {
        L10n.text(key, language: resolvedLanguage)
    }

    func localizedFormat(_ format: String, _ arguments: CVarArg...) -> String {
        L10n.format(format, language: resolvedLanguage, arguments: arguments)
    }

    func applyApplicationAppearance() {
        NSApp?.appearance = appearance.nsAppearance
    }
}

/// 文案直接内置在可执行文件中，避免 Swift Package 资源包未复制时出现“设置有效但界面没翻译”的半成品。
enum L10n {
    static func text(_ key: String, language: AppLanguage) -> String {
        guard language == .english else { return key }
        return english[key] ?? key
    }

    static func format(_ format: String, language: AppLanguage, arguments: [CVarArg]) -> String {
        let template = text(format, language: language)
        return String(format: template, locale: Locale(identifier: language == .english ? "en_US" : "zh_CN"),
                      arguments: arguments)
    }

    private static let english: [String: String] = [
        "设置": "Settings",
        "Aural 设置": "Aural Settings",
        "通用": "General",
        "开机启动": "Launch at Login",
        "登录 Mac 后自动运行 Aural。": "Automatically run Aural when you log in to your Mac.",
        "无法更改开机启动": "Could Not Change Launch at Login",
        "好": "OK",
        "语言": "Language",
        "界面语言": "Interface Language",
        "跟随系统": "System",
        "简体中文": "Chinese",
        "浅色": "Light",
        "深色": "Dark",
        "外观": "Appearance",
        "功能": "Features",
        "耳机控制": "Headphones",
        "显示耳机控制页": "Show Headphone Controls",
        "关闭后，耳机控制从主面板隐藏。": "Hide the headphone controls tab from the main panel when off.",
        "同时输出": "Simultaneous Output",
        "显示多设备输出": "Show Multi-Device Output",
        "关闭后，多设备输出功能从输出面板隐藏。":
            "When off, multi-device output is hidden from the Output panel.",
        "输出": "Output",
        "麦克风": "Microphone",
        "音频控制": "Audio Control",
        "更多操作": "More",
        "控制区域": "Control Sections",
        "打开 Aural": "Open Aural",
        "设置…": "Settings…",
        "立即刷新": "Refresh Now",
        "音频录制权限…": "Audio Recording Permission…",
        "未能打开系统设置，请手动进入隐私与安全性 → 屏幕与系统音频录制。":
            "Could not open System Settings. Open Privacy & Security → Screen & System Audio Recording manually.",
        "复制耳机诊断": "Copy Headphone Diagnostics",
        "退出 Aural": "Quit Aural",
        "退出": "Quit",
        "版本 %@": "Version %@",
        "重试释放": "Retry Release",
        "暂无正在播放的应用": "No Apps Playing Audio",
        "播放音频后，可在这里单独调节音量": "Play audio to adjust each app’s volume here.",
        "音频状态不可用": "Audio status unavailable",
        "等待音频流": "Waiting for audio stream",
        "应用播放增益，不影响麦克风输入": "App playback gain does not affect microphone input",
        "重试电平": "Retry Level",
        "重新应用音量": "Reapply Volume",
        "应用配置": "Apply Configuration",
        "停止管理": "Stop Managing",
        "未应用；请从选项中重新应用": "Not applied; reapply from the menu",
        "已应用音量配置": "Volume configuration applied",
        "正在读取实时电平": "Reading live levels",
        "等待音频流注册后应用": "Apply after the audio stream is registered",
        "尚未读取": "Not read yet",
        "低于负 60 dBFS": "Below -60 dBFS",
        "同时输出设备": "Simultaneous Output",
        "同时输出 · %d 台": "Simultaneous Output · %d Devices",
        "同时输出待释放": "Simultaneous Output Pending Release",
        "清理残留设备": "Clean Up Leftover Device",
        "关闭同时输出提示": "Dismiss Simultaneous Output Message",
        "不支持系统音量": "System volume unavailable",
        "不支持输入音量": "Input volume unavailable",
        "不支持统一音量": "Shared volume unavailable",
        "尚未读取设备控制状态": "Device controls not read",
        "%@ 尚未读取输入控制状态": "%@: input controls not read",
        "读取失败": "Read failed",
        "暂无可用麦克风": "No microphone available",
        "设备未公开静音状态": "Device does not expose mute state",
        "设备未公开可写的硬件静音控制": "Device does not expose writable hardware mute",
        "已静音": "Muted",
        "未静音": "Not muted",
        "切换设备静音": "Toggle device mute",
        "输入音量；不采集音频": "Input volume; does not capture audio",
        "设备音量；不会切换默认输出": "Device volume; does not change the default output",
        "设备音量只读": "Device volume is read-only",
        "设为默认输出：%@": "Set as default output: %@",
        "设为默认输入：%@": "Set as default input: %@",
        "切换为默认输出 · %@": "Switch to default output · %@",
        "切换为默认输入 · %@": "Switch to default input · %@",
        "结束同时输出，仅使用“%@”播放": "End simultaneous output and play only on “%@”",
        "%@ 静音": "Mute %@",
        "取消静音 %@": "Unmute %@",
        "静音 %@": "Mute %@",
        "取消静音": "Unmute",
        "静音": "Mute",
        "%@ 的实时音频电平": "Live audio level for %@",
        "%@ 的独立增益": "Independent gain for %@",
        "%@；右键打开应用操作": "%@; right-click for app actions",
        "%@ 的设备音量": "%@ device volume",
        "%@ 尚未读取设备控制状态": "%@: device controls not read",
        "%@ 的输入音量": "%@ input volume",
        "电平尚未读取": "Level not read",
        "实时音频电平": "Live audio level",
        "当前默认输出": "Current default output",
        "当前默认输入": "Current default input",
        "切换为默认输出": "Switch to default output",
        "切换为默认输入": "Switch to default input",
        "连接耳机": "Connect Headphones",
        "选择支持的蓝牙耳机作为系统输出后会自动连接":
            "Connect supported Bluetooth headphones as the system output to connect automatically",
        "重试": "Retry",
        "重新扫描": "Scan Again",
        "取消重连": "Cancel Reconnection",
        "刷新": "Refresh",
        "断开": "Disconnect",
        "取消": "Cancel",
        "耳机噪声控制": "Headphone Noise Control",
        "该耳机尚未确认噪声控制能力": "Noise control capability has not been confirmed",
        "正在断开耳机": "Disconnecting headphones",
        "耳机电量 %d%%": "Headphone battery %d%%",
        "无法确定当前耳机，请重新扫描": "Unable to identify the current headphones. Scan again.",
        "耳机控制尚未连接": "Headphone controls are not connected",
        "等待蓝牙授权与就绪": "Waiting for Bluetooth permission and readiness",
        "正在寻找耳机…": "Looking for headphones…",
        "请选择你的耳机": "Choose your headphones",
        "正在连接控制通道…": "Connecting the control channel…",
        "正在验证耳机服务…": "Verifying headphone services…",
        "正在验证耳机": "Verifying headphones",
        "已连接": "Connected",
        "正在断开控制通道…": "Disconnecting the control channel…",
        "控制连接失败": "Control connection failed",
        "关闭": "Off",
        "降噪": "Noise Cancellation",
        "透传": "Transparency",
        "抗风噪": "Wind Reduction",
        "自适应": "Adaptive",
        "耳机电量：%@": "Headphone battery: %@",
        "耳机电量：身份尚未确认": "Headphone battery: identity not verified",
        "耳机电量：未读取": "Headphone battery: not read",
        "耳机电量：读数无效": "Headphone battery: invalid reading",
        "耳机电量：%d%%": "Headphone battery: %d%%",
        "从同时输出移除：%@": "Remove from simultaneous output: %@",
        "加入同时输出：%@": "Add to simultaneous output: %@",
        "从同时输出移除“%@”": "Remove “%@” from simultaneous output",
        "将“%@”加入同时输出": "Add “%@” to simultaneous output",
        "切换“%@”静音": "Toggle mute for “%@”",
        "%@ 的同时输出音量": "Simultaneous output volume for %@",
        "调节“%@”独立音量；不会切换默认输出":
            "Adjust independent “%@” volume; does not change the default output",
        "收起同时输出设备": "Collapse simultaneous output devices",
        "展开并更改同时输出设备": "Expand and change simultaneous output devices",
        "取消同时输出静音": "Unmute simultaneous output",
        "静音同时输出": "Mute simultaneous output",
        "同时输出总音量": "Simultaneous output master volume",
        "选择一台扬声器继续播放": "Choose a speaker to continue playback",
        "上次的同时输出还在，清理后可重新设置":
            "Previous simultaneous output is still present; clean it up before setting up again",
        "选择上面的扬声器后，可调节 APP 音量与电平": "Select a speaker above to adjust app volume and levels",
        "同时输出时暂不支持 APP 独立音量与电平": "Per-app volume and levels are unavailable during simultaneous output",
        "当前系统输出不支持 APP 独立音量与电平": "The current system output does not support per-app volume and levels"
    ]
}

private struct AppLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppLanguage.chinese
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageEnvironmentKey.self] }
        set { self[AppLanguageEnvironmentKey.self] = newValue }
    }
}
