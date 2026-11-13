import AppKit
import SwiftUI
import AuralCore

/// 音效窗口的两个页面共享同一份 App 设置，但各自的处理与预设语义保持独立。
enum ApplicationAudioEffectPage: Hashable, CaseIterable {
    case equalizer
    case spatial
}

/// 独立音效窗口保留主面板的排版语言：小幅频响预览配合十根经典 EQ 推子。
struct ApplicationAudioEffectView: View {
    @ObservedObject var model: AppModel
    let applicationID: String
    let appName: String
    let applicationURL: URL?
    @ObservedObject private var appSettings = AppSettings.shared
    @StateObject private var draft: ApplicationAudioEffectDraft
    @StateObject private var presentation: ApplicationAudioEffectPresentation

    init(model: AppModel, applicationID: String,
         appName: String, applicationURL: URL?,
         initialPage: ApplicationAudioEffectPage = .equalizer) {
        self.model = model
        self.applicationID = applicationID
        self.appName = appName
        self.applicationURL = applicationURL
        _draft = StateObject(
            wrappedValue: ApplicationAudioEffectDraft(
                model.applicationAudioEffect(for: applicationID)
            )
        )
        let presentation = ApplicationAudioEffectPresentation()
        presentation.page = initialPage
        _presentation = StateObject(wrappedValue: presentation)
    }

    private var language: AppLanguage {
        appSettings.resolvedLanguage
    }

    var body: some View {
        GeometryReader { geometry in
            let hasNotice = !model.applicationEffectsEnabled
            let hasError = model.operationError != nil
            VStack(alignment: .leading, spacing: EqualizerLayoutMetrics.spacing) {
                header
                    .frame(height: EqualizerLayoutMetrics.headerHeight, alignment: .leading)
                pageTabs
                    .frame(height: EqualizerLayoutMetrics.pageTabHeight, alignment: .leading)
                if hasNotice {
                    totalSwitchNotice
                        .frame(height: EqualizerLayoutMetrics.noticeHeight, alignment: .leading)
                }
                if presentation.page == .equalizer {
                    // 曲线与推子共同吃掉剩余高度；出现提示或错误时自动缩短两块。
                    let heights = EqualizerLayoutMetrics.flexibleHeights(
                        in: geometry.size.height,
                        hasNotice: hasNotice,
                        hasError: hasError
                    )
                    presetToolbar
                        .frame(height: EqualizerLayoutMetrics.toolbarHeight, alignment: .leading)
                    EqualizerResponsePreview(
                        eq: draft.settings.eq,
                        enabled: draft.settings.enabled,
                        language: language
                    )
                    .frame(height: heights.curve)
                    EqualizerFaderBank(eq: draft.settings.eq,
                                       language: language,
                                       onPreview: previewGain,
                                       onCommit: commitGain)
                        .frame(height: heights.fader)
                } else {
                    SpatialEffectPage(
                        appName: appName,
                        settings: draft.settings.spatial,
                        language: language,
                        onPreviewIntensity: previewSpatialIntensity,
                        onCommitIntensity: commitSpatialIntensity,
                        onModeChange: commitSpatialMode
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let error = model.operationError {
                    PanelError(text: L10n.text(error, language: language))
                        .lineLimit(2)
                        .help(L10n.text(error, language: language))
                        .frame(height: EqualizerLayoutMetrics.errorHeight, alignment: .leading)
                }
            }
        }
        .padding(EqualizerLayoutMetrics.padding)
        .frame(width: ApplicationAudioEffectMetrics.width,
               height: ApplicationAudioEffectMetrics.height,
               alignment: .topLeading)
        .background(PanelStyle.canvas)
        .foregroundStyle(PanelStyle.ink)
        .tint(PanelStyle.accent)
        .preferredColorScheme(appSettings.appearance.colorScheme)
        .environment(\.appLanguage, language)
        .alert(L10n.text("另存为预设", language: language),
               isPresented: $presentation.showingSavePreset) {
            TextField(L10n.text("预设名称", language: language), text: $presentation.presetName)
            Button(L10n.text("取消", language: language), role: .cancel) {}
            Button(L10n.text("保存", language: language)) { savePreset() }
                .disabled(presentation.presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            // 弹窗说明只描述当前动作，不在界面里解释频段数量或预设用途。
            Text(L10n.text("保存当前配置", language: language))
        }
        .alert(L10n.text("重命名预设", language: language),
               isPresented: $presentation.showingRenamePreset) {
            TextField(L10n.text("预设名称", language: language), text: $presentation.presetName)
            Button(L10n.text("取消", language: language), role: .cancel) {}
            Button(L10n.text("重命名", language: language)) { renamePreset() }
                .disabled(presentation.presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(L10n.text("删除预设？", language: language),
               isPresented: $presentation.showingDeletePreset) {
            Button(L10n.text("取消", language: language), role: .cancel) {}
            Button(L10n.text("删除", language: language), role: .destructive) { deletePreset() }
        } message: {
            Text(L10n.text("已使用该预设的 App 会保留当前声音，并显示为“自定义”。", language: language))
        }
        .onDisappear {
            // A/B 仅用于当前试听，关闭窗口后必须恢复正式设置。
            model.setApplicationAudioEffectBypassed(false, for: applicationID)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Group {
                if let applicationURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: applicationURL.path))
                        .resizable()
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(PanelStyle.accent)
                }
            }
            .frame(width: 30, height: 30)
            .background(PanelStyle.surface, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 0) {
                Text(appName)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 16)
            PanelBooleanControl(isOn: enabledBinding)
                .frame(width: 112)
                .accessibilityLabel(L10n.text("启用应用音效", language: language))
        }
    }

    private var pageTabs: some View {
        PanelTabs(
            items: ApplicationAudioEffectPage.allCases,
            selection: presentation.page,
            title: { page in
                switch page {
                case .equalizer: return L10n.text("均衡器", language: language)
                case .spatial: return L10n.text("空间", language: language)
                }
            },
            select: { presentation.page = $0 }
        )
        .frame(maxWidth: .infinity)
    }

    private var presetToolbar: some View {
        HStack(spacing: 8) {
            Menu {
                Section(L10n.text("内置", language: language)) {
                    ForEach(AppAudioEffectPreset.allCases, id: \.self) { preset in
                        Button(presetTitle(preset)) {
                            var next = draft.settings
                            next.apply(preset)
                            commit(next)
                        }
                    }
                }
                if !model.appAudioEffectCustomPresets.isEmpty {
                    Section(L10n.text("我的预设", language: language)) {
                        ForEach(model.appAudioEffectCustomPresets) { preset in
                            Button(preset.name) {
                                var next = draft.settings
                                next.apply(custom: preset)
                                commit(next)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "waveform.path")
                    Text(activePresetTitle)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(PanelStyle.secondary)
                }
                .font(PanelStyle.bodyFont)
                .frame(minWidth: 150, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button(L10n.text("另存为预设", language: language)) {
                presentation.presetName = suggestedPresetName
                presentation.showingSavePreset = true
            }
            .buttonStyle(PanelButtonStyle())

            // 只有当前选中的是我的预设时，才允许直接更名或删除这个预设；不在底部再放管理入口。
            if let selectedCustomPreset {
                Button(L10n.text("重命名", language: language)) {
                    presentation.presetBeingRenamed = selectedCustomPreset.id
                    presentation.presetName = selectedCustomPreset.name
                    presentation.showingRenamePreset = true
                }
                .buttonStyle(PanelButtonStyle())

                Button(L10n.text("删除", language: language)) {
                    presentation.presetBeingDeleted = selectedCustomPreset.id
                    presentation.showingDeletePreset = true
                }
                .buttonStyle(PanelButtonStyle())
                .foregroundStyle(PanelStyle.error)
            }

            Spacer(minLength: 8)
            Button {
                model.setApplicationAudioEffectBypassed(
                    !model.isApplicationAudioEffectBypassed(for: applicationID),
                    for: applicationID
                )
            } label: {
                Label(L10n.text("对比原声", language: language),
                      systemImage: model.isApplicationAudioEffectBypassed(for: applicationID)
                          ? "waveform" : "waveform.badge.minus")
            }
            .buttonStyle(PanelButtonStyle(prominent: model.isApplicationAudioEffectBypassed(for: applicationID)))
            .disabled(!draft.settings.enabled || !model.applicationEffectsEnabled)
            .help(L10n.text("临时对比未处理的声音，不修改已保存设置", language: language))

            Button(L10n.text("重置", language: language)) {
                var next = draft.settings
                next.apply(.flat)
                commit(next)
            }
            .buttonStyle(PanelButtonStyle())
        }
    }

    private var totalSwitchNotice: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.circle")
            Text(L10n.text("设置中的“启用应用音效”当前已关闭，此配置会在重新开启后生效。",
                           language: language))
                .lineLimit(1)
                .help(L10n.text("设置中的“启用应用音效”当前已关闭，此配置会在重新开启后生效。",
                                language: language))
        }
        .font(PanelStyle.captionFont)
        .foregroundStyle(PanelStyle.secondary)
    }

    private var activePresetTitle: String {
        switch draft.settings.preset {
        case .builtIn(let preset):
            return presetTitle(preset)
        case .custom(let id):
            return model.appAudioEffectCustomPresets.first(where: { $0.id == id })?.name
                ?? L10n.text("我的预设", language: language)
        case .manual:
            return L10n.text("自定义", language: language)
        }
    }

    /// 当前选中的用户预设；手动调整或内置预设不提供针对预设库的重命名与删除。
    /// 保留模块内可见性，便于界面测试直接验证按钮出现条件。
    var selectedCustomPreset: AppAudioEffectCustomPreset? {
        guard case .custom(let id) = draft.settings.preset else { return nil }
        return model.appAudioEffectCustomPresets.first { $0.id == id }
    }

    private var suggestedPresetName: String {
        var index = model.appAudioEffectCustomPresets.count + 1
        var candidate = L10n.format("预设 %d", language: language, arguments: [index])
        while model.appAudioEffectCustomPresets.contains(where: { $0.name == candidate }) {
            index += 1
            candidate = L10n.format("预设 %d", language: language, arguments: [index])
        }
        return candidate
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { draft.settings.enabled },
            set: { enabled in
                var next = draft.settings
                next.enabled = enabled
                // 开关改变后一律退出 A/B；开启时必须立即听到设置，关闭时必须严格旁路。
                model.setApplicationAudioEffectBypassed(false, for: applicationID)
                commit(next)
            }
        )
    }

    /// 拖动中只改本地草稿并发布实时 DSP 参数；不写 UserDefaults，不启动会话协调。
    private func previewGain(at index: Int, to value: Float) {
        var next = draft.settings
        next.setGain(value, at: index)
        draft.settings = next
        model.previewApplicationAudioEffect(next, for: applicationID)
    }

    /// 松手后才把完整的十段设置写入配置，确保磁盘状态与最终音色一致。
    private func commitGain(at index: Int, to value: Float) {
        var next = draft.settings
        next.setGain(value, at: index)
        commit(next)
    }

    private func commit(_ settings: AppAudioEffectSettings) {
        draft.settings = settings
        model.setApplicationAudioEffect(settings, for: applicationID)
    }

    private func savePreset() {
        guard let preset = model.createApplicationAudioEffectPreset(
            named: presentation.presetName,
            eq: draft.settings.eq
        ) else { return }
        var next = draft.settings
        next.apply(custom: preset)
        commit(next)
        presentation.presetName = ""
    }

    private func renamePreset() {
        guard let presetBeingRenamed = presentation.presetBeingRenamed else { return }
        model.renameApplicationAudioEffectPreset(presetBeingRenamed, to: presentation.presetName)
        presentation.presetBeingRenamed = nil
        presentation.presetName = ""
    }

    private func deletePreset() {
        guard let presetBeingDeleted = presentation.presetBeingDeleted else { return }
        model.deleteApplicationAudioEffectPreset(presetBeingDeleted)
        presentation.presetBeingDeleted = nil
        draft.settings = model.applicationAudioEffect(for: applicationID)
    }

    /// 拖动混响强度时只更新实时原子参数，松手后再写入同一份逐 App 设置。
    private func previewSpatialIntensity(_ value: Float) {
        var next = draft.settings
        next.spatial.setIntensity(value)
        draft.settings = next
        model.previewApplicationAudioEffect(next, for: applicationID)
    }

    private func commitSpatialIntensity() {
        commit(draft.settings)
    }

    /// 空间模式不属于 EQ 预设；切换模式不会改变当前均衡器或自定义预设引用。
    private func commitSpatialMode(_ mode: AppAudioSpatialMode) {
        var next = draft.settings
        next.spatial.mode = mode
        commit(next)
    }

    private func presetTitle(_ preset: AppAudioEffectPreset) -> String {
        switch preset {
        case .flat: return L10n.text("平坦", language: language)
        case .voice: return L10n.text("语音增强", language: language)
        case .podcast: return L10n.text("播客", language: language)
        case .music: return L10n.text("音乐", language: language)
        case .movie: return L10n.text("电影", language: language)
        case .bassBoost: return L10n.text("低音增强", language: language)
        }
    }

    private func decibelText(_ value: Float) -> String {
        let rounded = (value * 2).rounded() / 2
        let text = abs(rounded.rounded() - rounded) < 0.001
            ? "\(Int(rounded.rounded()))"
            : String(format: "%.1f", rounded)
        return rounded > 0 ? "+\(text) dB" : "\(text) dB"
    }
}

/// 空间页只呈现模式与混响强度，不混入 EQ 预设和频段控件。
private struct SpatialEffectPage: View {
    let appName: String
    let settings: AppAudioSpatialSettings
    let language: AppLanguage
    let onPreviewIntensity: (Float) -> Void
    let onCommitIntensity: () -> Void
    let onModeChange: (AppAudioSpatialMode) -> Void

    private var duration: String {
        "\(Int((settings.intensity * 100).rounded()))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(PanelStyle.accent)
                    .frame(width: 30, height: 30)
                    .background(PanelStyle.iconSurface, in: RoundedRectangle(cornerRadius: 8))
                Text(L10n.text("空间效果", language: language))
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
            }

            PanelSegmentedControl(
                items: AppAudioSpatialMode.allCases,
                selection: Binding(
                    get: { settings.mode },
                    set: onModeChange
                ),
                title: modeTitle
            )

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L10n.text("混响强度", language: language))
                        .font(PanelStyle.bodyFont)
                        .foregroundStyle(PanelStyle.ink)
                    Spacer(minLength: 16)
                    Text(duration)
                        .font(PanelStyle.bodyFont.monospacedDigit())
                        .foregroundStyle(PanelStyle.secondary)
                        .frame(width: PanelStyle.percentageWidth, alignment: .trailing)
                }
                PanelVolumeSlider(
                    value: Binding(
                        get: { Double(settings.intensity) },
                        set: { onPreviewIntensity(Float($0)) }
                    ),
                    label: L10n.text("混响强度", language: language),
                    accessibilityValueText: duration,
                    onEditingChanged: { editing in
                        if !editing { onCommitIntensity() }
                    }
                )
                .disabled(!settings.mode.isEnabled)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func modeTitle(_ mode: AppAudioSpatialMode) -> String {
        switch mode {
        case .off: return L10n.text("关闭", language: language)
        case .room: return L10n.text("房间", language: language)
        case .hall: return L10n.text("大厅", language: language)
        case .vocalSpace: return L10n.text("人声空间", language: language)
        }
    }
}

/// CLT 当前工具链缺少 SwiftUI 的 @State 宏插件，因此弹窗与文本输入统一沿用 ObservableObject。
@MainActor
private final class ApplicationAudioEffectPresentation: ObservableObject {
    @Published var page: ApplicationAudioEffectPage = .equalizer
    @Published var showingSavePreset = false
    @Published var showingRenamePreset = false
    @Published var showingDeletePreset = false
    @Published var presetName = ""
    @Published var presetBeingRenamed: UUID?
    @Published var presetBeingDeleted: UUID?
}

/// 曲线只负责实时预览当前十段设置；调音交给下方推子，避免手指遮挡目标点。
private struct EqualizerResponsePreview: View {
    let eq: AppAudioEffectEQ
    let enabled: Bool
    let language: AppLanguage

    private let topInset: CGFloat = 12
    private let bottomInset: CGFloat = 28

    var body: some View {
        GeometryReader { geometry in
            // 十根推子按等宽列铺满整块内容；曲线网格的首末列必须与推子中心重合。
            let bandInset = EqualizerLayoutMetrics.bandInset(width: geometry.size.width)
            let plotSize = CGSize(
                width: max(1, EqualizerLayoutMetrics.plotWidth(width: geometry.size.width)),
                height: max(1, geometry.size.height - topInset - bottomInset)
            )
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(PanelStyle.surface.opacity(0.64))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(PanelStyle.line.opacity(0.85), lineWidth: 1)
                    }

                Canvas { context, _ in
                    drawGrid(context: &context, size: plotSize)
                    drawCurve(context: &context, size: plotSize)
                    drawZeroLine(context: &context, size: plotSize)
                }
                .frame(width: plotSize.width, height: plotSize.height)
                .offset(x: bandInset, y: topInset)

                yAxisLabels(size: plotSize)
                    .frame(width: bandInset - 5, height: plotSize.height)
                    .offset(y: topInset)

                frequencyLabels(size: plotSize)
                    .frame(width: plotSize.width, height: 20)
                    .offset(x: bandInset, y: topInset + plotSize.height + 4)

            }
            .help(L10n.text("频响曲线预览；使用下方推子调整",
                            language: language))
            .opacity(enabled ? 1 : 0.8)
        }
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        for index in AppAudioEffectEQ.frequencies.indices {
            let x = xPosition(for: index, width: size.width)
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(PanelStyle.line.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 0.7, dash: [2, 3]))
        }
        for gain in stride(from: Float(-12), through: Float(12), by: 6) {
            let y = yPosition(for: gain, height: size.height)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path,
                           with: .color(gain == 0
                                        ? PanelStyle.secondary.opacity(0.35)
                                        : PanelStyle.line.opacity(0.55)),
                           style: StrokeStyle(lineWidth: gain == 0 ? 1 : 0.7, dash: gain == 0 ? [] : [3, 4]))
        }
    }

    private func drawCurve(context: inout GraphicsContext, size: CGSize) {
        let points = AppAudioEffectEQ.frequencies.indices.map { index in
            CGPoint(
                x: xPosition(for: index, width: size.width),
                y: yPosition(for: eq[index], height: size.height)
            )
        }
        guard let first = points.first, let last = points.last else { return }
        let curve = smoothPath(points: points)
        var fill = curve
        fill.addLine(to: CGPoint(x: last.x, y: size.height))
        fill.addLine(to: CGPoint(x: first.x, y: size.height))
        fill.closeSubpath()
        context.fill(
            fill,
            with: .linearGradient(
                Gradient(colors: [PanelStyle.accent.opacity(0.10), PanelStyle.accent.opacity(0.005)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
        context.stroke(curve, with: .color(PanelStyle.accent),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    private func drawZeroLine(context: inout GraphicsContext, size: CGSize) {
        let y = yPosition(for: 0, height: size.height)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: size.width, y: y))
        context.stroke(path, with: .color(PanelStyle.secondary.opacity(0.55)),
                       style: StrokeStyle(lineWidth: 1))
    }

    private func smoothPath(points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        for index in 0..<(points.count - 1) {
            let previous = points[max(0, index - 1)]
            let start = points[index]
            let end = points[index + 1]
            let following = points[min(points.count - 1, index + 2)]
            let control1 = CGPoint(
                x: start.x + (end.x - previous.x) / 6,
                y: start.y + (end.y - previous.y) / 6
            )
            let control2 = CGPoint(
                x: end.x - (following.x - start.x) / 6,
                y: end.y - (following.y - start.y) / 6
            )
            path.addCurve(to: end, control1: control1, control2: control2)
        }
        return path
    }

    private func yAxisLabels(size: CGSize) -> some View {
        ZStack(alignment: .topTrailing) {
            ForEach([Float(12), 6, 0, -6, -12], id: \.self) { gain in
                Text(gain > 0 ? "+\(Int(gain))" : "\(Int(gain))")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(PanelStyle.secondary)
                    .position(x: 14, y: yPosition(for: gain, height: size.height))
            }
        }
    }

    private func frequencyLabels(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(AppAudioEffectEQ.frequencies.indices, id: \.self) { index in
                Text(frequencyText(index))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(PanelStyle.secondary)
                    .position(x: xPosition(for: index, width: size.width), y: 8)
            }
        }
    }

    private func xPosition(for index: Int, width: CGFloat) -> CGFloat {
        EqualizerLayoutMetrics.bandPosition(index, plotWidth: width)
    }

    private func yPosition(for gain: Float, height: CGFloat) -> CGFloat {
        let clamped = min(AppAudioEffectSettings.maximumGainDB,
                          max(AppAudioEffectSettings.minimumGainDB, gain))
        let ratio = (AppAudioEffectSettings.maximumGainDB - clamped)
            / (AppAudioEffectSettings.maximumGainDB - AppAudioEffectSettings.minimumGainDB)
        return height * CGFloat(ratio)
    }

    private func frequencyText(_ index: Int) -> String {
        let frequency = AppAudioEffectEQ.frequencies[index]
        if frequency >= 1_000 {
            return "\(Int(frequency / 1_000))K"
        }
        return "\(Int(frequency))"
    }

    private func decibelText(_ value: Float) -> String {
        let rounded = (value * 2).rounded() / 2
        let text = abs(rounded.rounded() - rounded) < 0.001
            ? "\(Int(rounded.rounded()))"
            : String(format: "%.1f", rounded)
        return rounded > 0 ? "+\(text) dB" : "\(text) dB"
    }
}

/// 经典 Graphic EQ 推子：竖向拖动即时试听，松手后提交；双击将该频段归零。
private struct EqualizerFaderBank: View {
    let eq: AppAudioEffectEQ
    let language: AppLanguage
    let onPreview: (Int, Float) -> Void
    let onCommit: (Int, Float) -> Void

    var body: some View {
        GeometryReader { geometry in
            let columnWidth = geometry.size.width / CGFloat(AppAudioEffectEQ.bandCount)
            let trackHeight = max(100, geometry.size.height - EqualizerLayoutMetrics.faderLabelHeight)
            ZStack(alignment: .topLeading) {
                ForEach(0..<AppAudioEffectEQ.bandCount, id: \.self) { index in
                    EqualizerFader(
                        index: index,
                        gain: eq[index],
                        trackHeight: trackHeight,
                        language: language,
                        onPreview: { onPreview(index, $0) },
                        onCommit: { onCommit(index, $0) }
                    )
                    .frame(width: columnWidth, height: geometry.size.height, alignment: .top)
                    .position(
                        x: EqualizerLayoutMetrics.faderCenter(index, width: geometry.size.width),
                        y: geometry.size.height / 2
                    )
                }
            }
        }
    }
}

private struct EqualizerFader: View {
    let index: Int
    let gain: Float
    let trackHeight: CGFloat
    let language: AppLanguage
    let onPreview: (Float) -> Void
    let onCommit: (Float) -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(compactDecibelText(gain))
                .font(.system(size: 10, weight: .regular).monospacedDigit())
                .foregroundStyle(gain == 0 ? PanelStyle.secondary : PanelStyle.ink)
                .lineLimit(1)

            GeometryReader { geometry in
                let height = max(1, geometry.size.height - 8)
                ZStack(alignment: .top) {
                    Capsule()
                        .fill(PanelStyle.line.opacity(0.8))
                        .frame(width: 3)
                        .frame(maxHeight: .infinity)
                    Rectangle()
                        .fill(PanelStyle.secondary.opacity(0.45))
                        .frame(width: 18, height: 1)
                        .position(x: geometry.size.width / 2,
                                  y: 4 + height / 2)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(PanelStyle.tabSelection)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(gain == 0
                                              ? PanelStyle.line
                                              : PanelStyle.accent.opacity(0.8),
                                              lineWidth: 1)
                        }
                        .frame(width: 24, height: 15)
                        .shadow(color: PanelStyle.ink.opacity(0.10), radius: 1, y: 1)
                        .position(x: geometry.size.width / 2,
                                  y: 4 + faderY(for: gain, height: height))
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .onChanged { value in
                                    let relative = value.location.y - 4
                                    onPreview(Self.gain(at: relative, height: height))
                                }
                                .onEnded { value in
                                    let relative = value.location.y - 4
                                    onCommit(Self.gain(at: relative, height: height))
                                }
                        )
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    onPreview(0)
                    onCommit(0)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.format("%@ 增益", language: language,
                                                arguments: [frequencyText(AppAudioEffectEQ.frequencies[index])]))
                .accessibilityValue(decibelText(gain))
                .accessibilityAdjustableAction { direction in
                    let delta: Float = direction == .increment ? 0.5 : -0.5
                    let next = AppAudioEffectEQ.snappedGain(gain + delta)
                    onPreview(next)
                    onCommit(next)
                    return
                }
            }
            .frame(height: trackHeight)

            Text(frequencyText(AppAudioEffectEQ.frequencies[index]))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(PanelStyle.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func faderY(for gain: Float, height: CGFloat) -> CGFloat {
        let ratio = (AppAudioEffectSettings.maximumGainDB - gain)
            / (AppAudioEffectSettings.maximumGainDB - AppAudioEffectSettings.minimumGainDB)
        return min(height, max(0, height * CGFloat(ratio)))
    }

    private static func gain(at y: CGFloat, height: CGFloat) -> Float {
        let ratio = 1 - min(1, max(0, y / max(1, height)))
        let value = AppAudioEffectSettings.minimumGainDB
            + Float(ratio) * (AppAudioEffectSettings.maximumGainDB
                              - AppAudioEffectSettings.minimumGainDB)
        return AppAudioEffectEQ.snappedGain(value)
    }

    private func compactDecibelText(_ value: Float) -> String {
        let text = decibelText(value)
        return text.replacingOccurrences(of: " dB", with: "")
    }

    private func decibelText(_ value: Float) -> String {
        let rounded = AppAudioEffectEQ.snappedGain(value)
        let text = abs(rounded.rounded() - rounded) < 0.001
            ? "\(Int(rounded.rounded()))"
            : String(format: "%.1f", rounded)
        return rounded > 0 ? "+\(text) dB" : "\(text) dB"
    }

    private func frequencyText(_ frequency: Float) -> String {
        if frequency >= 1_000 {
            return "\(Int(frequency / 1_000))K"
        }
        return "\(Int(frequency))"
    }
}

/// CLT 当前工具链缺少 SwiftUI 的 @State 宏插件，因此沿用工程已有的 ObservableObject 草稿模式。
@MainActor
private final class ApplicationAudioEffectDraft: ObservableObject {
    @Published var settings: AppAudioEffectSettings

    init(_ settings: AppAudioEffectSettings) {
        self.settings = settings
    }
}

enum ApplicationAudioEffectMetrics {
    static let width: CGFloat = 720
    static let height: CGFloat = 500
    static var size: CGSize { CGSize(width: width, height: height) }
}

/// 曲线网格、频率标签与十根推子共享一套列坐标，避免三个区域各自内缩造成错位。
enum EqualizerLayoutMetrics {
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 10
    static let headerHeight: CGFloat = 30
    static let pageTabHeight: CGFloat = 27
    static let toolbarHeight: CGFloat = 26
    static let noticeHeight: CGFloat = 18
    static let errorHeight: CGFloat = 30
    static let minimumCurveHeight: CGFloat = 130
    static let maximumCurveHeight: CGFloat = 160
    static let minimumFaderHeight: CGFloat = 150
    static let faderLabelHeight: CGFloat = 36
    private static let curveShare: CGFloat = 0.42

    static func rowCount(hasNotice: Bool, hasError: Bool) -> Int {
        5 + (hasNotice ? 1 : 0) + (hasError ? 1 : 0)
    }

    static func fixedHeight(hasNotice: Bool, hasError: Bool) -> CGFloat {
        headerHeight + pageTabHeight + toolbarHeight
            + (hasNotice ? noticeHeight : 0)
            + (hasError ? errorHeight : 0)
    }

    static func flexibleSpace(in height: CGFloat, hasNotice: Bool, hasError: Bool) -> CGFloat {
        height - fixedHeight(hasNotice: hasNotice, hasError: hasError)
            - spacing * CGFloat(rowCount(hasNotice: hasNotice, hasError: hasError) - 1)
    }

    /// 剩余高度全部分配给曲线和推子；底部不再保留固定空白，附加提示也不会挤掉内容。
    static func flexibleHeights(in height: CGFloat,
                                hasNotice: Bool,
                                hasError: Bool) -> (curve: CGFloat, fader: CGFloat) {
        let space = flexibleSpace(in: height, hasNotice: hasNotice, hasError: hasError)
        let curve = min(maximumCurveHeight, max(minimumCurveHeight, space * curveShare))
        let fader = max(minimumFaderHeight, space - curve)
        return (curve, fader)
    }

    static func bandInset(width: CGFloat) -> CGFloat {
        width / CGFloat(AppAudioEffectEQ.bandCount * 2)
    }

    static func plotWidth(width: CGFloat) -> CGFloat {
        width - bandInset(width: width) * 2
    }

    static func bandPosition(_ index: Int, plotWidth: CGFloat) -> CGFloat {
        plotWidth * CGFloat(index) / CGFloat(AppAudioEffectEQ.bandCount - 1)
    }

    static func gridX(_ index: Int, width: CGFloat) -> CGFloat {
        bandInset(width: width) + bandPosition(index, plotWidth: plotWidth(width: width))
    }

    static func faderCenter(_ index: Int, width: CGFloat) -> CGFloat {
        (CGFloat(index) + 0.5) * width / CGFloat(AppAudioEffectEQ.bandCount)
    }
}
