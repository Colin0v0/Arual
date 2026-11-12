import AppKit
import Combine
import AuralCore

/// 所有未获授权状态均使用独立原生对话框，APP 分区始终不展示权限提示条或按钮。
@MainActor
final class AudioCaptureAccessAlertController {
    private var subscription: AnyCancellable?
    private var warningWasPresented = false
    private var isPresenting = false
    private let currentAccess: () -> SystemAudioCaptureAccess
    private let language: () -> AppLanguage
    private let beforePresenting: () -> Void
    private let openSettings: () -> Void
    private let requestAccess: () -> Void
    private let presentAlert: (NSAlert) -> NSApplication.ModalResponse

    init(access: AnyPublisher<SystemAudioCaptureAccess, Never>,
         currentAccess: @escaping () -> SystemAudioCaptureAccess,
         language: @escaping () -> AppLanguage,
         beforePresenting: @escaping () -> Void,
         openSettings: @escaping () -> Void,
         requestAccess: @escaping () -> Void,
         presentAlert: @escaping (NSAlert) -> NSApplication.ModalResponse) {
        self.currentAccess = currentAccess
        self.language = language
        self.beforePresenting = beforePresenting
        self.openSettings = openSettings
        self.requestAccess = requestAccess
        self.presentAlert = presentAlert
        // 延后至主 RunLoop：不在模型刷新、启动或音频资源清理的调用栈内进入模态循环。
        subscription = access.receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 展示前读取最新值，不弹出已恢复授权的过期提示。
                self.accessChanged(self.currentAccess())
            }
        }
    }

    private func accessChanged(_ access: SystemAudioCaptureAccess) {
        if access == .authorized {
            // 仅真实恢复授权才开始新一轮提示；取消或状态在未知/拒绝间变化都不反复打扰。
            warningWasPresented = false
            return
        }
        guard !warningWasPresented, !isPresenting else { return }
        warningWasPresented = true
        isPresenting = true
        defer { isPresenting = false }
        beforePresenting()
        let response = presentAlert(Self.makeAlert(access: access, language: language()))
        if access == .notDetermined {
            if response == .alertFirstButtonReturn {
                // 用户主动申请后若被系统拒绝，允许下一次提示提供设置入口。
                warningWasPresented = false
                requestAccess()
            } else if response == .alertSecondButtonReturn {
                openSettings()
            }
        } else if response == .alertFirstButtonReturn {
            openSettings()
        }
    }

    static func makeAlert(access: SystemAudioCaptureAccess, language: AppLanguage) -> NSAlert {
        precondition(access != .authorized, "已经授权时不应创建权限提示框")
        let alert = NSAlert()
        alert.alertStyle = .warning
        if access == .unavailable {
            alert.messageText = L10n.text("无法检查系统音频录制权限", language: language)
            alert.informativeText = L10n.text("App 音频控制已暂停，请检查系统权限后重新打开 Aural。", language: language)
        } else {
            alert.messageText = L10n.text("需要系统音频录制权限", language: language)
            alert.informativeText = L10n.text(
                "请在系统设置中允许 Aural 录制系统音频，以使用应用音量、电平和音频路由。授权后若系统要求重新打开 Aural，请按系统提示操作。",
                language: language)
        }
        if access == .notDetermined {
            alert.addButton(withTitle: L10n.text("允许访问", language: language))
        }
        alert.addButton(withTitle: L10n.text("打开系统设置", language: language))
        let cancel = alert.addButton(withTitle: L10n.text("取消", language: language))
        cancel.keyEquivalent = "\u{1b}"
        return alert
    }
}
