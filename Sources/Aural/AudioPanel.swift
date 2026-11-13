import SwiftUI
import AuralCore

struct AudioPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var layout: PanelPresentationLayout
    @ObservedObject private var updates = AuralUpdateChecker.shared
    let openSettings: () -> Void
    var openApplicationAudioEffects: (String, String, URL?) -> Void = { _, _, _ in }
    let panelSizeChanged: (CGSize) -> Void
    let surface: MeterSurface
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var selection = PanelSelection()
    private final class PanelSelection: ObservableObject {
        @Published var page: AudioPanelPage = .output
    }

    private var pages: [AudioPanelPage] {
        AudioPanelPage.available(showHeadphoneControls: settings.showHeadphoneControls)
    }

    private var currentPage: AudioPanelPage {
        pages.contains(selection.page) ? selection.page : .output
    }

    var body: some View {
        // 原生容器是显示高度的唯一来源，动画中的中间高度只用于排版，不回写目标尺寸。
        GeometryReader { container in
            VStack(spacing: 0) {
                header.padding(.horizontal, PanelMetrics.horizontalInset).frame(height: 44)
                PanelTabs(items: pages, selection: currentPage,
                          title: { $0.title(language: settings.resolvedLanguage) }) { page in
                    // 单层导航直接选择内容页，并按该页的自然高度调整原生外框。
                    selection.page = page
                    layout.selectPage(page)
                    model.setApplicationMetersSelected(applicationMetersSelected, for: surface)
                }
                .accessibilityLabel(settings.localized("控制区域"))
                .padding(.horizontal, PanelMetrics.horizontalInset).padding(.bottom, 9)

                // 三个内容页各自保留测量与滚动位置，耳机页不再被设备列表或麦克风页撑高。
                PanelPageViewport(items: pages, selection: currentPage,
                                  height: max(0, container.size.height - PanelMetrics.chromeHeight),
                                  pageHeightsChanged: layout.reportPageHeights) { page in
                    VStack(alignment: .leading, spacing: 10) {
                        switch page {
                        case .output:
                            applicationControls(direction: .output,
                                                metersVisible: currentPage == .output)
                        case .microphone:
                            applicationControls(direction: .input,
                                                metersVisible: currentPage == .microphone)
                        case .headphones:
                            // 耳机页只呈现耳机功能，设备音量与麦克风入口都留在音量页。
                            HeadphoneControlsSection(group: model.headphones)
                        }
                    }
                    // 内容页不再叠加外层水平 padding；设备行和应用行的行内留白负责左右对称。
                    .padding(.top, 1).padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                footer.frame(height: 34)
            }
        }
        // 背景覆盖原生动画中的完整外框，避免缩放过程出现透明空隙或页脚跳到中间。
        .frame(width: PanelMetrics.width)
        .font(PanelStyle.bodyFont)
        .foregroundStyle(PanelStyle.ink)
        .tint(PanelStyle.accent)
        // 菜单栏浮层的底色由 NSPanel 原生图层绘制，页面保持透明；
        // 独立控制窗口仍由页面自己铺满背景。
        .background(surface == .popover ? Color.clear : PanelStyle.canvas)
        .preferredColorScheme(settings.appearance.colorScheme)
        .environment(\.appLanguage, settings.resolvedLanguage)
        .onAppear {
            // 模型独立于设置窗口生命周期；面板出现时同步一次总开关，避免直接读取窗口局部状态。
            model.setApplicationEffectsEnabled(settings.appAudioEffectsEnabled)
            layout.selectPage(currentPage)
            model.setApplicationMetersSelected(applicationMetersSelected, for: surface)
        }
        .onChange(of: settings.showHeadphoneControls) { _, shown in
            if !shown, selection.page == .headphones {
                selection.page = .output
                layout.selectPage(AudioPanelPage.output)
                model.setApplicationMetersSelected(applicationMetersSelected, for: surface)
            }
        }
        // 只提交确定的目标尺寸，AppKit 负责外框动画，SwiftUI 不产生第二套尺寸插值。
        .onChange(of: panelSize, initial: true) { _, size in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { panelSizeChanged(size) }
        }
    }

    private var applicationMetersSelected: Bool {
        currentPage.displaysApplications
    }

    private func applicationControls(direction: AudioDeviceDirection,
                                     metersVisible: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasErrors { errors }
            switch direction {
            case .output:
                if let audio = model.audio {
                    OutputRoutingSection(audio: audio, routing: model.outputRouting,
                                         select: model.selectOutput,
                                         setVolume: { model.setOutputVolume($0, on: $1) },
                                         setMuted: { model.setOutputMuted($0, on: $1) },
                                         stop: model.stopSimultaneousOutput,
                                         dismissError: model.dismissSimultaneousOutputError,
                                         setSimultaneousVolume: model.setSimultaneousOutputVolume,
                                         setSimultaneousMuted: model.setSimultaneousOutputMuted,
                                         toggleMember: model.toggleSimultaneousMember,
                                         showSimultaneousOutput: settings.showSimultaneousOutput)
                }
            case .input:
                microphoneControls
            }
            PanelDivider().padding(.horizontal, PanelMetrics.horizontalInset)
            // 两个设备页都使用相同模型与回调，APP 音量依然是播放增益，不冒充麦克风混音。
            ApplicationVolumeSection(model: model, metersVisible: metersVisible,
                                     routingEnabled: direction == .output
                                         && currentPage == .output
                                         && model.applicationAudioRoutingEnabled,
                                     effectsEnabled: model.applicationEffectsEnabled,
                                     openApplicationAudioEffects: openApplicationAudioEffects)
        }
    }

    private var microphoneControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.inputError { PanelError(text: settings.localized(error)).padding(.horizontal, PanelMetrics.horizontalInset) }
            if let error = model.inputOperationError { PanelError(text: settings.localized(error)).padding(.horizontal, PanelMetrics.horizontalInset) }
            if let input = model.inputAudio {
                InputDevicesSection(audio: input, select: model.selectInput,
                                    setVolume: { model.setInputVolume($0, on: $1) },
                                    setMuted: { model.setInputMuted($0, on: $1) })
            }
        }
    }

    private var panelSize: CGSize {
        layout.size
    }

    // 按可见内容而非透明点击框对齐右边距，中英文使用同一规则。
    private func trailingAction(_ button: PanelActionButton) -> PanelActionButton {
        var button = button
        button.alignsContentToTrailing = true
        return button
    }

    private var header: some View {
        HStack(spacing: 7) {
            // 主面板与菜单栏、App 图标使用同一个品牌标记。
            AuralBrandMark(size: 18)
            Text("Aural").font(PanelStyle.titleFont)
            Spacer()
            updateBadge
            // 齿轮就是设置入口，左键直接打开设置窗口；诊断与系统权限留在右键菜单。
            trailingAction(PanelActionButton(systemName: "gearshape", title: settings.localized("设置"),
                              hoverStyle: .foregroundOnly, action: openSettings, menu: makeOptionsMenu))
                .frame(width: PanelActionMetrics.size, height: PanelActionMetrics.size)
        }
    }

    @ViewBuilder private var updateBadge: some View {
        AuralUpdateCapsule(updates: updates, settings: settings)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            PanelDivider()
            HStack {
                // 底栏显示真实版本号，跟随发布版本自动更新，不提供点击或悬停装饰。
                Text("v\(AuralVersion.current)").foregroundStyle(PanelStyle.secondary)
                Spacer()
                trailingAction(PanelActionButton(settings.localized("退出"), hoverStyle: .foregroundOnly) { NSApp.terminate(nil) })
                    .help(settings.localized("退出 Aural"))
            }.padding(.horizontal, PanelMetrics.horizontalInset).padding(.vertical, 3)
        }
    }

    private var hasErrors: Bool {
        model.audioError != nil
            || model.operationError != nil
            || model.appAudioEffectPersistenceError != nil
            || !model.cleanupErrors.isEmpty
    }

    private var errors: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.audioError { PanelError(text: settings.localized(error)) }
            if let error = model.operationError { PanelError(text: settings.localized(error)) }
            if let error = model.appAudioEffectPersistenceError {
                PanelError(text: settings.localized(error))
            }
            ForEach(model.cleanupErrors.keys.sorted(), id: \.self) { key in
                if let error = model.cleanupErrors[key] { PanelError(text: settings.localized(error)) }
            }
            if !model.cleanupErrors.isEmpty {
                Button(settings.localized("重试释放")) { model.stopAll() }.buttonStyle(PanelButtonStyle())
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func makeOptionsMenu() -> NSMenu {
        let menu = NSMenu()
        // 菜单每次点击时生成，诊断可用状态与当前耳机数据保持一致。
        menu.autoenablesItems = false
        let version = NSMenuItem(title: "Aural \(AuralVersion.current)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(.separator())
        menu.addItem(PanelActionMenuItem(title: settings.localized("设置…"), handler: openSettings))
        menu.addItem(PanelActionMenuItem(title: settings.localized("立即刷新"), handler: { model.refresh() }))
        if let update = updates.availableUpdate {
            switch updates.phase {
            case .ready:
                menu.addItem(PanelActionMenuItem(title: settings.localizedFormat("重启以更新到 %@", update.version)) {
                    updates.restartAndInstall()
                })
            case .downloading(let progress):
                let label = progress > 0
                    ? settings.localizedFormat("正在下载更新 %@ · %d%%", update.version, Int((progress * 100).rounded()))
                    : settings.localizedFormat("正在下载更新 %@…", update.version)
                let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case .preparing:
                let item = NSMenuItem(title: settings.localizedFormat("正在准备更新 %@…", update.version),
                                      action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case .available, .failed, .idle:
                menu.addItem(PanelActionMenuItem(title: settings.localizedFormat("更新到 %@", update.version)) {
                    updates.downloadAndPrepare()
                })
            }
        } else {
            let check = PanelActionMenuItem(title: settings.localized(updates.isChecking ? "正在检查更新…" : "检查更新…")) {
                updates.check(force: true)
            }
            check.isEnabled = !updates.isChecking
            menu.addItem(check)
        }
        menu.addItem(.separator())
        menu.addItem(PanelActionMenuItem(title: settings.localized("音频录制权限…")) {
            model.openAudioCaptureSettings()
        })
        let diagnostic = PanelActionMenuItem(title: settings.localized("复制耳机诊断")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.headphones.diagnosticLines.joined(separator: "\n"), forType: .string)
        }
        diagnostic.isEnabled = !model.headphones.diagnosticLines.isEmpty
        menu.addItem(diagnostic)
        return menu
    }

}
