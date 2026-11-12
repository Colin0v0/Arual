import AppKit
import Combine
import Testing
import AuralCore
@testable import Aural

@MainActor
struct AudioCaptureAccessAlertTests {
    @Test func nativeAlertHasLocalizedSettingsAndCancelButtons() {
        for language: AppLanguage in [.chinese, .english] {
            let alert = AudioCaptureAccessAlertController.makeAlert(access: .denied, language: language)
            #expect(alert.alertStyle == .warning)
            #expect(alert.messageText == L10n.text("需要系统音频录制权限", language: language))
            #expect(alert.buttons.map(\.title) == [L10n.text("打开系统设置", language: language),
                                                  L10n.text("取消", language: language)])
            #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
            #expect(!alert.informativeText.isEmpty)
            if language == .english { #expect(alert.messageText == "System Audio Recording Permission Required") }
        }
    }

    @Test func deniedAtStartupPresentsOnceAndOnlySettingsResponseOpensSettings() {
        let access = CurrentValueSubject<SystemAudioCaptureAccess, Never>(.denied)
        var presentations = 0
        var dismissals = 0
        var settings = 0
        let controller = AudioCaptureAccessAlertController(
            access: access.eraseToAnyPublisher(), currentAccess: { access.value }, language: { .chinese },
            beforePresenting: { dismissals += 1 }, openSettings: { settings += 1 }, requestAccess: {},
            presentAlert: { _ in
                #expect(dismissals == 1)
                presentations += 1
                return .alertFirstButtonReturn
            })
        flushMainRunLoop()
        for _ in 0..<5 { access.send(.denied); flushMainRunLoop() }
        #expect(presentations == 1 && dismissals == 1 && settings == 1)
        withExtendedLifetime(controller) {}
    }

    @Test func cancellingDoesNotRepromptUntilPermissionWasRestoredAndRevokedAgain() {
        let access = CurrentValueSubject<SystemAudioCaptureAccess, Never>(.denied)
        var presentations = 0
        var settings = 0
        let controller = AudioCaptureAccessAlertController(
            access: access.eraseToAnyPublisher(), currentAccess: { access.value }, language: { .english },
            beforePresenting: {}, openSettings: { settings += 1 }, requestAccess: {},
            presentAlert: { _ in presentations += 1; return .alertSecondButtonReturn })
        flushMainRunLoop()
        for status: SystemAudioCaptureAccess in [.denied, .notDetermined, .unavailable, .denied] {
            access.send(status)
            flushMainRunLoop()
        }
        #expect(presentations == 1 && settings == 0)
        access.send(.authorized)
        flushMainRunLoop()
        access.send(.denied)
        flushMainRunLoop()
        #expect(presentations == 2 && settings == 0)
        withExtendedLifetime(controller) {}
    }

    @Test func authorizedAndObsoleteWarningsDoNotPresentAnAlert() {
        let access = CurrentValueSubject<SystemAudioCaptureAccess, Never>(.authorized)
        var presentations = 0
        let controller = AudioCaptureAccessAlertController(
            access: access.eraseToAnyPublisher(), currentAccess: { access.value }, language: { .chinese },
            beforePresenting: {}, openSettings: {}, requestAccess: {},
            presentAlert: { _ in presentations += 1; return .alertSecondButtonReturn })
        access.send(.notDetermined)
        access.send(.denied)
        access.send(.authorized)
        flushMainRunLoop()
        #expect(presentations == 0)
        withExtendedLifetime(controller) {}
    }

    @Test func undecidedAndUnavailablePermissionsAlsoUseNativeAlerts() {
        for initial: SystemAudioCaptureAccess in [.notDetermined, .unavailable] {
            let access = CurrentValueSubject<SystemAudioCaptureAccess, Never>(initial)
            var presentations = 0
            let controller = AudioCaptureAccessAlertController(
                access: access.eraseToAnyPublisher(), currentAccess: { access.value }, language: { .chinese },
                beforePresenting: {}, openSettings: {}, requestAccess: {},
                presentAlert: { alert in
                    presentations += 1
                    #expect(alert.buttons.contains { $0.title == "打开系统设置" })
                    return .abort
                })
            flushMainRunLoop()
            access.send(initial)
            flushMainRunLoop()
            #expect(presentations == 1)
            withExtendedLifetime(controller) {}
        }
    }

    @Test func undecidedAlertRequestsAccessOrOpensSettingsAccordingToSelectedButton() {
        for response: NSApplication.ModalResponse in [.alertFirstButtonReturn, .alertSecondButtonReturn, .alertThirdButtonReturn] {
            let access = CurrentValueSubject<SystemAudioCaptureAccess, Never>(.notDetermined)
            var requests = 0
            var settings = 0
            let controller = AudioCaptureAccessAlertController(
                access: access.eraseToAnyPublisher(), currentAccess: { access.value }, language: { .english },
                beforePresenting: {}, openSettings: { settings += 1 }, requestAccess: { requests += 1 },
                presentAlert: { alert in
                    #expect(alert.buttons.map(\.title) == ["Allow Access", "Open System Settings", "Cancel"])
                    return response
                })
            flushMainRunLoop()
            #expect(requests == (response == .alertFirstButtonReturn ? 1 : 0))
            #expect(settings == (response == .alertSecondButtonReturn ? 1 : 0))
            withExtendedLifetime(controller) {}
        }
    }

    private func flushMainRunLoop() {
        // 仅测试排空主线程订阅；注入的 presenter 不显示窗口或修改真实系统权限。
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    }
}
