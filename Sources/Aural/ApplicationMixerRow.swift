import SwiftUI
import AuralCore

/// 纯布局视图，真实信号与操作由模型注入；可单独验证整行尺寸，不启动音频或耳机。
struct ApplicationMixerRow: View {
    let app: ApplicationAudioRow
    let state: ApplicationMixState
    let levelSource: ApplicationLevelSource
    let metersVisible: Bool
    let awaitingStream: Bool
    let status: String
    let effectsAvailable: Bool
    let audioEffect: AppAudioEffectSettings
    let routingEnabled: Bool
    let audioRoute: AppAudioRoute
    let routeOutputs: [AudioOutput]
    let toggleMute: () -> Void
    let setGain: (Float) -> Void
    let retryMeter: () -> Void
    let applyConfiguration: () -> Void
    let stopManaging: () -> Void
    let updateAudioEffect: (AppAudioEffectSettings) -> Void
    let openApplicationAudioEffects: () -> Void
    let setAudioRoute: (AppAudioRoute) -> Void
    let toggleRouteOutput: (String) -> Void
    @Environment(\.appLanguage) private var language
    @StateObject private var hover: PanelRowHoverState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 真实应用行默认静止；视觉快照可显式打开首帧悬停，不依赖合成鼠标事件。
    init(app: ApplicationAudioRow, state: ApplicationMixState,
         levelSource: ApplicationLevelSource, metersVisible: Bool,
         awaitingStream: Bool, status: String, toggleMute: @escaping () -> Void,
         setGain: @escaping (Float) -> Void, retryMeter: @escaping () -> Void,
         applyConfiguration: @escaping () -> Void, stopManaging: @escaping () -> Void,
         effectsAvailable: Bool = false,
         audioEffect: AppAudioEffectSettings = .disabled,
         updateAudioEffect: @escaping (AppAudioEffectSettings) -> Void = { _ in },
         openApplicationAudioEffects: @escaping () -> Void = {},
         routingEnabled: Bool = false, audioRoute: AppAudioRoute = .allOutputs,
         routeOutputs: [AudioOutput] = [],
         setAudioRoute: @escaping (AppAudioRoute) -> Void = { _ in },
         toggleRouteOutput: @escaping (String) -> Void = { _ in },
         initiallyHovered: Bool = false) {
        self.app = app
        self.state = state
        self.levelSource = levelSource
        self.metersVisible = metersVisible
        self.awaitingStream = awaitingStream
        self.status = status
        self.effectsAvailable = effectsAvailable
        self.audioEffect = audioEffect
        self.routingEnabled = routingEnabled
        self.audioRoute = audioRoute
        self.routeOutputs = routeOutputs
        self.toggleMute = toggleMute
        self.setGain = setGain
        self.retryMeter = retryMeter
        self.applyConfiguration = applyConfiguration
        self.stopManaging = stopManaging
        self.updateAudioEffect = updateAudioEffect
        self.openApplicationAudioEffects = openApplicationAudioEffects
        self.setAudioRoute = setAudioRoute
        self.toggleRouteOutput = toggleRouteOutput
        _hover = StateObject(wrappedValue: PanelRowHoverState(active: initiallyHovered))
    }

    var body: some View {
        // 全部控件保持一排，真实错误放入同行标记、悬停和菜单，不再额外撑出第二行。
        HStack(spacing: 8) {
            if metersVisible {
                LiveApplicationLevelMeter(source: levelSource, applicationName: app.label)
            } else {
                // 非当前分区不订阅 30Hz 电平；切回该页时再恢复实时观察。
                ApplicationLevelMeter(level: nil, applicationName: app.label)
            }
            Group {
                if let url = app.applicationURL {
                    Image(nsImage: ApplicationIconCache.icon(for: url)).resizable()
                } else {
                    Image(systemName: "waveform").foregroundStyle(PanelStyle.secondary)
                }
            }
            .frame(width: 22, height: 22)
            .overlay(alignment: .bottomTrailing) {
                if let error = state.failure {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10)).foregroundStyle(.red)
                        .background(PanelStyle.canvas, in: Circle())
                        .help(L10n.text(error, language: language))
                        .accessibilityLabel(L10n.text(error, language: language))
                } else if state.managed && awaitingStream {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                        .help(L10n.text("等待音频流", language: language))
                }
            }
            Text(app.label).lineLimit(1).help(app.bundleID)
                .frame(width: applicationNameWidth, alignment: .leading)
            PanelActionButton(systemName: state.muted ? "speaker.slash.fill" : "speaker.wave.2",
                              title: state.muted
                                  ? L10n.format("取消静音 %@", language: language, arguments: [app.label])
                                  : L10n.format("静音 %@", language: language, arguments: [app.label]),
                              hoverStyle: .foregroundOnly, action: toggleMute)
            .help(L10n.text(state.muted ? "取消静音" : "静音", language: language))
            .accessibilityLabel(state.muted
                                ? L10n.format("取消静音 %@", language: language, arguments: [app.label])
                                : L10n.format("静音 %@", language: language, arguments: [app.label]))
            .accessibilityValue(L10n.text(state.muted ? "已静音" : "未静音", language: language))
            PanelVolumeSlider(value: Binding(get: { Double(state.gain) }, set: { setGain(Float($0)) }),
                              label: L10n.format("%@ 的独立增益", language: language, arguments: [app.label]))
                .frame(minWidth: sliderMinimumWidth)
                .help(L10n.text("应用播放增益，不影响麦克风输入", language: language))
            PanelPercentage(value: state.gain, highlighted: hover.active)
            if effectsAvailable {
                effectButton
            }
            if routingEnabled {
                routingButton
            }
        }
        .padding(.horizontal, PanelMetrics.horizontalInset).padding(.vertical, 9)
        .panelContentHover(hover.active)
        .onHover { hover.active = $0 }
        // 应用行仅改变读数颜色，不再绘制包住整行的灰框。
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hover.active)
        .help(state.failure.map { L10n.text($0, language: language) }
              ?? L10n.format("%@；右键打开应用操作", language: language, arguments: [status]))
        .contextMenu { options }
    }

    private var trailingControlCount: Int {
        (effectsAvailable ? 1 : 0) + (routingEnabled ? 1 : 0)
    }

    /// 两个入口同时出现时只压缩应用名与滑杆的弹性空间，不增加行高。
    private var applicationNameWidth: CGFloat {
        switch trailingControlCount {
        case 0: return 128
        case 1: return 112
        default: return 96
        }
    }

    private var sliderMinimumWidth: CGFloat {
        switch trailingControlCount {
        case 0: return PanelMetrics.compactSliderMinimumWidth
        case 1: return 124
        default: return 112
        }
    }

    /// 音效入口与路由按钮同尺寸；只有该应用启用音效时才使用 Accent Color。
    private var effectButton: some View {
        PanelActionButton(
            systemName: "slider.horizontal.3",
            title: effectTitle,
            tint: audioEffect.enabled ? PanelStyle.accent : nil,
            hoverStyle: .foregroundOnly,
            action: openApplicationAudioEffects
        )
        .help(effectTitle)
    }

    private var effectTitle: String {
        guard audioEffect.enabled else {
            return L10n.text("音效：关闭", language: language)
        }
        let preset: String
        preset = effectPresetTitle
        return L10n.format("音效：%@", language: language, arguments: [preset])
    }

    /// 行图标只显示简短状态，具体预设名和十段数值都在独立窗口中读取。
    private var effectPresetTitle: String {
        switch audioEffect.preset {
        case .builtIn(.flat): return L10n.text("平坦", language: language)
        case .builtIn(.voice): return L10n.text("语音增强", language: language)
        case .builtIn(.podcast): return L10n.text("播客", language: language)
        case .builtIn(.music): return L10n.text("音乐", language: language)
        case .builtIn(.movie): return L10n.text("电影", language: language)
        case .builtIn(.bassBoost): return L10n.text("低音增强", language: language)
        case .custom: return L10n.text("我的预设", language: language)
        case .manual: return L10n.text("已修改", language: language)
        }
    }

    @ViewBuilder private var options: some View {
        if let error = state.failure {
            Text(L10n.text(error, language: language))
            Divider()
            if !state.managed { Button(L10n.text("重试电平", language: language), action: retryMeter) }
            Button(L10n.text("重新应用音量", language: language), action: applyConfiguration)
        } else if !state.managed {
            Button(L10n.text("应用配置", language: language), action: applyConfiguration)
        }
        if state.managed { Button(L10n.text("停止管理", language: language), action: stopManaging) }
    }

    /// 路由按钮保持 26pt 方形并沿用现有前景悬停规则，避免应用行因为新增入口撑高。
    private var routingButton: some View {
        var button = PanelActionButton(
            systemName: "arrow.triangle.branch",
            title: routingTitle,
            tint: audioRoute.isCustom ? PanelStyle.accent : nil,
            hoverStyle: .foregroundOnly,
            menu: { routeMenu() }
        )
        button.showsMenuOnClick = true
        return button
    }

    private var routingTitle: String {
        guard audioRoute.isCustom else {
            return L10n.text("全部输出：自动包含新增设备", language: language)
        }
        let names = routeOutputs
            .filter { audioRoute.customDeviceUIDs.contains($0.uid) }
            .map(\.name)
        guard !names.isEmpty else {
            return L10n.text("自定义路由暂不可用，当前按全部输出播放", language: language)
        }
        return L10n.format("自定义输出：%@", language: language,
                           arguments: [names.joined(separator: language == .english ? ", " : "、")])
    }

    /// 菜单只保留“全部输出”与单个设备选择，不再提供额外恢复操作。
    private func routeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let allOutputs = PanelActionMenuItem(title: L10n.text("全部输出（默认）", language: language)) {
            setAudioRoute(.allOutputs)
        }
        allOutputs.state = audioRoute == .allOutputs ? .on : .off
        menu.addItem(allOutputs)

        let activeUIDs = Set(routeOutputs.map(\.uid))
        let selectedActiveUIDs = audioRoute.isCustom
            ? audioRoute.customDeviceUIDs.intersection(activeUIDs)
            : activeUIDs

        if !routeOutputs.isEmpty {
            menu.addItem(.separator())
        }
        for output in routeOutputs {
            let item = PanelActionMenuItem(title: output.name) {
                toggleRouteOutput(output.uid)
            }
            let isSelected = selectedActiveUIDs.contains(output.uid)
            item.state = isSelected ? .on : .off
            // 最后一个有效输出不能通过菜单取消；保留唯一目标，避免出现空路由错误。
            item.isEnabled = !(isSelected && selectedActiveUIDs.count == 1)
            menu.addItem(item)
        }

        if audioRoute.isCustom, selectedActiveUIDs.isEmpty {
            let unavailable = NSMenuItem(title: L10n.text("自定义路由暂不可用，当前按全部输出播放", language: language),
                                         action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            menu.addItem(unavailable)
        }
        return menu
    }
}

/// 应用图标在多次轮询和页面切换间复用，避免每帧都向 Launch Services 查询。
@MainActor
private enum ApplicationIconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()

    static func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}
