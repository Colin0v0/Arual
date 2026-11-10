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
    let toggleMute: () -> Void
    let setGain: (Float) -> Void
    let retryMeter: () -> Void
    let applyConfiguration: () -> Void
    let stopManaging: () -> Void
    @Environment(\.appLanguage) private var language

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
                .frame(width: 128, alignment: .leading)
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
                .frame(minWidth: PanelMetrics.compactSliderMinimumWidth)
                .help(L10n.text("应用播放增益，不影响麦克风输入", language: language))
            PanelPercentage(value: state.gain)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .help(state.failure.map { L10n.text($0, language: language) }
              ?? L10n.format("%@；右键打开应用操作", language: language, arguments: [status]))
        .contextMenu { options }
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
