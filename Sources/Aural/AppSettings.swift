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
        static let currentDeviceBattery = "local.aural.settings.showCurrentDeviceBattery"
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
    @Published var showCurrentDeviceBattery: Bool {
        didSet { defaults.set(showCurrentDeviceBattery, forKey: Key.currentDeviceBattery) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = AppLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .system
        appearance = AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        // 耳机控制、多设备输出与菜单栏电量都是可选能力，首次启动默认关闭。
        showHeadphoneControls = defaults.object(forKey: Key.headphones) as? Bool ?? false
        showSimultaneousOutput = defaults.object(forKey: Key.simultaneousOutput) as? Bool ?? false
        showCurrentDeviceBattery = defaults.object(forKey: Key.currentDeviceBattery) as? Bool ?? false
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
        "左 %d%%": "L %d%%",
        "右 %d%%": "R %d%%",
        "盒 %d%%": "Case %d%%",
        "正在切换音频路由…": "Switching the audio route…",
        "未佩戴，戴回后恢复控制": "Not worn. Controls resume when worn again.",
        "等待佩戴": "Waiting to be worn",
        "Apple 耳机拒绝了本次模式切换，当前模式已重新读取；请确认佩戴状态后再操作":
            "The headphones rejected this mode change. The actual mode was read again. Check that they are worn before trying again.",
        "已选设备均暂不可用，等待原设备恢复": "All selected devices are temporarily unavailable. Waiting for them to return.",
        "部分设备暂不可用，正通过其余已选设备播放；恢复后自动加入":
            "Playing through the remaining selected devices. Unavailable members will rejoin when they return.",
        "没有已连接且支持控制的耳机": "No supported headphones connected",
        "耳机已断开或不再是蓝牙输出设备": "Headphones disconnected or no longer available as a Bluetooth output",
        "耳机设备已移除，停止向旧控制目标发送数据": "Headphones removed; control commands have stopped",
        "请先连接支持控制的 B&W 耳机": "Connect supported B&W headphones first",
        "控制的耳机": "Headphone to control",
        "启用耳机控制": "Enable headphone controls",
        "停止控制": "Stop controlling",
        "耳机控制已暂停": "Headphone controls paused",
        "选择要控制的耳机": "Select a headphone to control",
        "当前仅支持原生 Float32 单声道或双声道 PCM；未启用音频接管": "Only native Float32 mono or stereo PCM is supported; audio processing was not enabled.",
        "正在等待系统确认输出…": "Waiting for macOS to confirm the output…",
        "实际输出：%@": "Actual output: %@",
        "提示音输出：%@": "Sound effects output: %@",
        "媒体与提示音输出不一致，请明确选择输出设备": "Media and sound effects use different outputs. Select an output explicitly.",
        "路由仍在等待系统确认，请稍后重新应用": "Waiting for output confirmation. Apply again once it completes.",
        "请先选择一台真实输出设备，再重新应用": "Select a physical output before applying again.",
        "已请求离开旧组合": "Requested departure from the previous group",
        "已确认离开旧组合": "Confirmed departure from the previous group",
        "已释放旧组合": "Released the previous group",
        "已创建并校验新组合": "Created and validated the new group",
        "已请求目标输出": "Requested the target output",
        "已确认目标输出": "Confirmed the target output",
        "已按真实播放通道恢复被抢占的默认输出": "Restored the preempted default output to the real playback route",
        "系统默认输出被反复抢占；Aural 已跟随真实输出并停止争抢。若为 AirPods，请在蓝牙设置中把“连接到此 Mac”改为“上次连接此 Mac 时”。":
            "The system default output keeps being taken over. Aural followed the real output and stopped fighting for it. For AirPods, set “Connect to This Mac” to “When Last Connected to This Mac” in Bluetooth settings.",
        "系统未在期限内确认媒体与提示音输出": "macOS did not confirm both output routes before the deadline",
        "系统未在期限内释放组合设备，请重试释放": "macOS did not confirm group removal before the deadline. Retry cleanup.",
        "系统未在期限内释放残留组合，请重试释放": "macOS did not confirm removal of the remaining group before the deadline. Retry cleanup.",
        "系统输出已在 Aural 外改变；未自动抢回，请确认实际输出后重新选择": "Output changed outside Aural. It was not switched back; verify the actual output and select again.",
        "应用未在期限内跟随已确认输出，请重新应用": "The app did not follow the confirmed output before the deadline. Apply again.",
        "设置": "Settings",
        "Aural 设置": "Aural Settings",
        "通用": "General",
        "开机启动": "Launch at Login",
        "登录 Mac 后自动运行 Aural。": "Start Aural when you log in.",
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
        "关闭后，耳机控制从主面板隐藏。": "Show the Headphones tab.",
        "显示多设备输出": "Show Multi-Device Output",
        "关闭后，多设备输出功能从输出面板隐藏。":
            "Show multi-device output options.",
        "显示当前设备剩余电量": "Show Device Battery",
        "在菜单栏 Aural 图标右侧显示当前设备电量。":
            "Show battery in the menu bar.",
        "输出": "Output",
        "麦克风": "Microphone",
        "音频控制": "Audio Control",
        "更多操作": "More",
        "控制区域": "Control Sections",
        "打开 Aural": "Open Aural",
        "设置…": "Settings…",
        "立即刷新": "Refresh Now",
        "更新": "Update",
        "正在下载 %d%%": "Downloading %d%%",
        "正在下载…": "Downloading…",
        "更新中…": "Updating…",
        "进行中": "In Progress",
        "发现新版本 %@": "Version %@ is available",
        "打开更新 %@": "Open Update %@",
        "跳过 %@": "Skip %@",
        "下载中": "Downloading",
        "准备中": "Preparing",
        "重启以更新": "Restart to Update",
        "重试更新": "Retry Update",
        "更新到 %@ 失败：%@": "Update to %@ failed: %@",
        "正在下载更新 %@ · %d%%": "Downloading update %@ · %d%%",
        "正在下载更新 %@…": "Downloading update %@…",
        "正在准备更新 %@…": "Preparing update %@…",
        "重启以更新到 %@": "Restart to Update to %@",
        "检查更新…": "Check for Updates…",
        "检查更新": "Check for Updates",
        "未发现新版本": "No Updates Available",
        "正在检查更新…": "Checking for Updates…",
        "正在检查…": "Checking…",
        "检查失败，重试": "Check Failed, Retry",
        "检查 GitHub 上的 Aural 更新": "Check GitHub for Aural updates",
        "更新到 %@": "Update to %@",
        "音频录制权限…": "Audio Recording Permission…",
        "未允许系统音频录制，App 音量、电平和路由暂不可用":
            "System audio recording is not allowed. App volume, levels, and routing are unavailable.",
        "请允许系统音频录制，以使用 App 音量、电平和路由":
            "Allow system audio recording to use app volume, levels, and routing.",
        "无法检查系统音频录制权限，App 音频控制已暂停":
            "Cannot check system audio recording permission. App audio controls are paused.",
        "已允许系统音频录制": "System audio recording is allowed",
        "系统音频录制尚未授权": "System audio recording is not authorized",
        "允许访问": "Allow Access",
        "打开系统设置": "Open System Settings",
        "需要系统音频录制权限": "System Audio Recording Permission Required",
        "请在系统设置中允许 Aural 录制系统音频，以使用应用音量、电平和音频路由。授权后若系统要求重新打开 Aural，请按系统提示操作。":
            "Allow Aural to record system audio in System Settings to use app volume, levels, and audio routing. If macOS asks you to reopen Aural after granting access, follow its instructions.",
        "重新检查": "Check Again",
        "无法检查系统音频录制权限": "Cannot Check System Audio Recording Permission",
        "App 音频控制已暂停，请检查系统权限后重新打开 Aural。":
            "App audio controls are paused. Check system permissions, then reopen Aural.",
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
        "多设备输出": "Multi-Device Output",
        "多设备输出 · %d 台": "Multi-Device Output · %d Devices",
        "多设备输出待释放": "Multi-Device Output Pending Release",
        "清理残留设备": "Clean Up Leftover Device",
        "关闭多设备输出提示": "Dismiss Multi-Device Output Message",
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
        "结束多设备输出，仅使用“%@”播放": "End multi-device output and play only on “%@”",
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
        "连接支持的蓝牙耳机后会自动启用控制":
            "Control connects automatically for supported Bluetooth headphones",
        "重试": "Retry",
        "重新扫描": "Scan Again",
        "取消重连": "Cancel Reconnection",
        "刷新": "Refresh",
        "断开": "Disconnect",
        "取消": "Cancel",
        "耳机噪声控制": "Headphone Noise Control",
        "该耳机尚未确认噪声控制能力": "Noise control capability has not been confirmed",
        "正在断开耳机": "Disconnecting headphones",
        "正在充电": "Charging",
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
        "开启": "On",
        "降噪": "Noise Cancellation",
        "透传": "Transparency",
        "抗风噪": "Wind Reduction",
        "自适应": "Adaptive",
        "耳机电量：%@": "Headphone battery: %@",
        "耳机电量：身份尚未确认": "Headphone battery: identity not verified",
        "耳机电量：未读取": "Headphone battery: not read",
        "耳机电量：读数无效": "Headphone battery: invalid reading",
        "耳机电量：%d%%": "Headphone battery: %d%%",
        "从多设备输出移除：%@": "Remove from multi-device output: %@",
        "加入多设备输出：%@": "Add to multi-device output: %@",
        "从多设备输出移除“%@”": "Remove “%@” from multi-device output",
        "将“%@”加入多设备输出": "Add “%@” to multi-device output",
        "切换“%@”静音": "Toggle mute for “%@”",
        "%@ 的多设备输出音量": "Multi-device output volume for %@",
        "调节“%@”独立音量；不会切换默认输出":
            "Adjust independent “%@” volume; does not change the default output",
        "收起多设备输出": "Collapse multi-device output",
        "展开并更改多设备输出": "Expand and change multi-device output",
        "取消多设备输出静音": "Unmute multi-device output",
        "静音多设备输出": "Mute multi-device output",
        "多设备输出总音量": "Multi-device output master volume",
        "选择一台扬声器继续播放": "Choose a speaker to continue playback",
        "上次的多设备输出还在，清理后可重新设置":
            "Previous multi-device output is still present; clean it up before setting up again",
        "选择上面的扬声器后，可调节 APP 音量与电平": "Select a speaker above to adjust app volume and levels",
        "当前系统输出不支持 APP 独立音量与电平": "The current system output does not support per-app volume and levels",
        "全部输出": "All Outputs",
        "全部输出（默认）": "All Outputs (Default)",
        "全部输出：自动包含新增设备": "All Outputs: new group devices are included automatically",
        "自定义输出：%@": "Custom output: %@",
        "至少选择一台输出设备": "Select at least one output device",
        "应用路由仅在多设备输出模式下可用":
            "App routing is available only in multi-device output mode",
        "应用路由目标必须来自当前多设备输出组":
            "App routing targets must belong to the current multi-device group",
        "该应用没有稳定身份，不能设置持久应用路由":
            "This app has no stable identity, so its route cannot be saved",
        "自定义路由暂不可用，当前按全部输出播放":
            "The custom route is temporarily unavailable. Playing through all available outputs.",
        "已应用自定义路由": "Custom route applied",
        "应用路由配置无法读取，请检查本地设置":
            "Could not read the app routing configuration. Check the local settings.",
        "应用路由配置无法保存，请检查本地设置":
            "Could not save the app routing configuration. Check the local settings."
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
