import SwiftUI
import AuralCore

struct ApplicationVolumeSection: View {
    @ObservedObject var model: AppModel
    /// 只有当前可见的设备分区订阅实时电平，隐藏页仍保留滚动位置但不做 30Hz 重绘。
    let metersVisible: Bool
    /// 应用路由只在输出页、且多设备组已确认时显示，麦克风页不提供输出路由入口。
    let routingEnabled: Bool
    /// 音效总开关由设置页控制；关闭时保留各 App 已保存的参数但隐藏入口。
    let effectsEnabled: Bool
    /// 应用行只负责发起打开请求，窗口生命周期由 StatusPanelController 持有。
    var openApplicationAudioEffects: (String, String, URL?) -> Void = { _, _, _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("APP").font(.system(size: 11, weight: .medium)).foregroundStyle(PanelStyle.secondary)
                .padding(.leading, PanelMetrics.horizontalInset)
            // 所有权限状态都由独立原生对话框处理，APP 分区不插入提示或授权按钮。
            if let reason = model.applicationAudioUnavailableReason {
                // 系统多输出负责原始播放；不展示看似可用、实际只有单流能力的应用滑杆。
                Text(L10n.text(reason, language: language))
                    .font(PanelStyle.captionFont).foregroundStyle(PanelStyle.secondary).padding(12)
            } else {
                VStack(spacing: 0) {
                    if let error = model.appAudioRoutePersistenceError {
                        PanelError(text: L10n.text(error, language: language)).padding(16)
                    }
                    // 持久化错误由主面板顶部统一显示，APP 区不重复撑高菜单栏浮层。
                    if let error = model.processError {
                        PanelError(text: L10n.text(error, language: language)).padding(16)
                    }
                    if model.playingApplications.isEmpty && model.processError == nil {
                        emptyState
                    }
                    ForEach(model.playingApplications) { app in
                        if let state = model.mixStates[app.id] {
                            applicationRow(app, state: state)
                                .transition(PanelStyle.transition(reduceMotion: reduceMotion))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // 只监听成员变化，不给每两秒轮询和拖动滑杆附加动画，避免读数追赶指针。
                .animation(PanelStyle.animation(reduceMotion: reduceMotion), value: model.playingApplications.map(\.id))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "speaker.wave.2").font(.system(size: 20, weight: .light))
                .foregroundStyle(PanelStyle.secondary).padding(.bottom, 3).accessibilityHidden(true)
            Text(L10n.text("暂无正在播放的应用", language: language))
            Text(L10n.text("播放音频后，可在这里单独调节音量", language: language))
                .font(PanelStyle.captionFont).foregroundStyle(PanelStyle.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
            .padding(.horizontal, PanelMetrics.horizontalInset)
    }

    private func applicationRow(_ app: ApplicationAudioRow, state: ApplicationMixState) -> some View {
        ApplicationMixerRow(app: app, state: state,
                            levelSource: model.levelSource(for: app.id),
                            metersVisible: metersVisible,
                            awaitingStream: state.managed && model.sessions[app.id]?.isActive != true,
                            status: status(for: app, state: state),
                            toggleMute: { model.toggleApplicationMute(app.id) },
                            setGain: { model.setApplicationGain($0, for: app.id) },
                            retryMeter: { model.retryMeter(app.id) },
                            applyConfiguration: { model.applyApplication(app.id) },
                            stopManaging: { model.stopManaging(app.id) },
                            effectsAvailable: effectsEnabled && model.hasStableApplicationRouteIdentity(app.id),
                            audioEffect: model.applicationAudioEffect(for: app.id),
                            updateAudioEffect: { model.setApplicationAudioEffect($0, for: app.id) },
                            openApplicationAudioEffects: {
                                openApplicationAudioEffects(app.id, app.label, app.applicationURL)
                            },
                            routingEnabled: routingEnabled,
                            audioRoute: model.applicationAudioRoute(for: app.id),
                            routeOutputs: model.availableApplicationRouteOutputs,
                            setAudioRoute: { model.setApplicationAudioRoute($0, for: app.id) },
                            toggleRouteOutput: { model.toggleApplicationAudioRouteDevice($0, for: app.id) })
            // 只禁用 APP 音频处理；上方硬件音量、设备切换和麦克风控制仍可使用。
            .disabled(!model.audioCaptureAccess.allowsApplicationAudio)
    }

    private func status(for app: ApplicationAudioRow, state: ApplicationMixState) -> String {
        if !model.audioCaptureAccess.allowsApplicationAudio {
            return L10n.text("系统音频录制尚未授权", language: language)
        }
        if state.failure != nil { return L10n.text("未应用；请从选项中重新应用", language: language) }
        if model.processError != nil { return L10n.text("音频状态不可用", language: language) }
        if let session = model.sessions[app.id], session.isActive {
            if model.effectiveApplicationAudioEffect(for: app.id) != nil {
                return L10n.text("已启用应用音效", language: language)
            }
            if model.effectiveApplicationAudioRoute(for: app.id).isCustom {
                return L10n.text("已应用自定义路由", language: language)
            }
            if model.applicationAudioRoute(for: app.id).isCustom {
                return L10n.text("自定义路由暂不可用，当前按全部输出播放", language: language)
            }
            return L10n.text(session.mode == .mixing ? "已应用音量配置" : "正在读取实时电平",
                             language: language)
        }
        if state.managed { return L10n.text("等待音频流注册后应用", language: language) }
        return L10n.text(app.registrationLabel, language: language)
    }
}
