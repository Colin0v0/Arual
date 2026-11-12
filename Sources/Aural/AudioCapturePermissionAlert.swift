import AppKit

/// 系统拒绝系统音频录制权限后展示的独立原生对话框。
/// 该对话框只负责解释结果并打开系统设置，不冒充 macOS 的首次授权提示。
@MainActor
enum AudioCapturePermissionAlert {
    static let systemSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    static func makeAlert(language: AppLanguage) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("需要系统音频录制权限", language: language)
        alert.informativeText = L10n.text(
            "Aural 需要系统音频录制权限才能调节应用音量、显示电平和控制应用输出。请在系统设置中开启 Aural，然后重新打开应用。",
            language: language)
        alert.addButton(withTitle: L10n.text("打开系统设置", language: language))
        let quit = alert.addButton(withTitle: L10n.text("退出", language: language))
        quit.keyEquivalent = "\u{1b}"
        return alert
    }

    /// 两种选择都会结束当前进程：拒绝授权后不留下无法使用的后台界面。
    static func handle(response: NSApplication.ModalResponse,
                       openSettings: @MainActor () -> Bool,
                       terminate: @MainActor () -> Void) {
        if response == .alertFirstButtonReturn {
            _ = openSettings()
        }
        terminate()
    }

    static func present(language: AppLanguage,
                        presentAlert: @MainActor (NSAlert) -> NSApplication.ModalResponse = {
                            NSApp.activate(ignoringOtherApps: true)
                            return $0.runModal()
                        },
                        openSettings: @MainActor () -> Bool = {
                            NSWorkspace.shared.open(systemSettingsURL)
                        },
                        terminate: @MainActor () -> Void = {
                            NSApp.terminate(nil)
                        }) {
        let response = presentAlert(makeAlert(language: language))
        handle(response: response, openSettings: openSettings, terminate: terminate)
    }
}
