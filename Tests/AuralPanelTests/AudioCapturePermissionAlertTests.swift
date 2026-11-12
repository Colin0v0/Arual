import AppKit
import Testing
@testable import Aural

@MainActor
struct AudioCapturePermissionAlertTests {
    @Test func deniedAlertUsesLocalizedSettingsAndQuitButtons() {
        for language: AppLanguage in [.chinese, .english] {
            let alert = AudioCapturePermissionAlert.makeAlert(language: language)
            #expect(alert.alertStyle == .warning)
            #expect(alert.messageText == L10n.text("需要系统音频录制权限", language: language))
            #expect(alert.buttons.map(\.title) == [
                L10n.text("打开系统设置", language: language),
                L10n.text("退出", language: language)
            ])
            #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
            #expect(alert.informativeText
                == L10n.text("Aural 需要系统音频录制权限才能调节应用音量、显示电平和控制应用输出。请在系统设置中开启 Aural，然后重新打开应用。",
                             language: language))
        }
    }

    @Test func systemSettingsButtonOpensTheCapturedAudioPaneAndAlwaysTerminates() {
        var settings = 0
        var terminated = 0
        AudioCapturePermissionAlert.handle(response: .alertFirstButtonReturn,
                                           openSettings: { settings += 1; return true },
                                           terminate: { terminated += 1 })
        #expect(settings == 1)
        #expect(terminated == 1)
        #expect(AudioCapturePermissionAlert.systemSettingsURL.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    @Test(arguments: [NSApplication.ModalResponse.alertSecondButtonReturn, .abort])
    func quitAndWindowCloseNeverEnterAnUnusableInterface(response: NSApplication.ModalResponse) {
        var settings = 0
        var terminated = 0
        AudioCapturePermissionAlert.handle(response: response,
                                           openSettings: { settings += 1; return true },
                                           terminate: { terminated += 1 })
        #expect(settings == 0)
        #expect(terminated == 1)
    }
}
