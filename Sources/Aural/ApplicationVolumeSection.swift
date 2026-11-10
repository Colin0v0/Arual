import SwiftUI
import AuralCore

struct ApplicationVolumeSection: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("APP").font(.system(size: 11, weight: .medium)).foregroundStyle(PanelStyle.secondary)
                .padding(.leading, 12)
            if let reason = model.applicationAudioUnavailableReason {
                // 系统多输出负责原始播放；不展示看似可用、实际只有单流能力的应用滑杆。
                Text(L10n.text(reason, language: language))
                    .font(PanelStyle.captionFont).foregroundStyle(PanelStyle.secondary).padding(12)
            } else {
                VStack(spacing: 0) {
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
        .frame(maxWidth: .infinity).padding(.vertical, 18).padding(.horizontal, 14)
    }

    private func applicationRow(_ app: ApplicationAudioRow, state: ApplicationMixState) -> some View {
        ApplicationMixerRow(app: app, state: state, level: model.meterLevels[app.id],
                            awaitingStream: state.managed && model.sessions[app.id]?.isActive != true,
                            status: status(for: app, state: state),
                            toggleMute: { model.toggleApplicationMute(app.id) },
                            setGain: { model.setApplicationGain($0, for: app.id) },
                            retryMeter: { model.retryMeter(app.id) },
                            applyConfiguration: { model.applyApplication(app.id) },
                            stopManaging: { model.stopManaging(app.id) })
    }

    private func status(for app: ApplicationAudioRow, state: ApplicationMixState) -> String {
        if state.failure != nil { return L10n.text("未应用；请从选项中重新应用", language: language) }
        if model.processError != nil { return L10n.text("音频状态不可用", language: language) }
        if let session = model.sessions[app.id], session.isActive {
            return L10n.text(session.mode == .mixing ? "已应用音量配置" : "正在读取实时电平",
                             language: language)
        }
        if state.managed { return L10n.text("等待音频流注册后应用", language: language) }
        return L10n.text(app.registrationLabel, language: language)
    }
}
