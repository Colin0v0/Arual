import AppKit
import SwiftUI

/// 音效窗口沿用设置窗口的生命周期：保留已保存的设置，关闭时只销毁临时试听旁路。
final class ApplicationAudioEffectWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            makeFirstResponder(nil)
        }
        super.sendEvent(event)
    }
}

@MainActor
final class ApplicationAudioEffectWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: ApplicationAudioEffectWindow?
    private var currentApplicationID: String?

    init(model: AppModel) {
        self.model = model
    }

    /// 重复点击同一 App 只把窗口带到前面；切换 App 时复用窗口，避免每次创建一组实时设置视图。
    func show(applicationID: String, appName: String, applicationURL: URL?) {
        // 同一 App 再次点击只前置窗口，保留本次试听的 A/B 状态，不重复创建音频设置视图。
        if let window, currentApplicationID == applicationID {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // 切换到另一个 App 时，旧 App 的运行时旁路必须立即恢复。
        if let currentApplicationID {
            model.setApplicationAudioEffectBypassed(false, for: currentApplicationID)
        }

        let effectWindow: ApplicationAudioEffectWindow
        if let window {
            effectWindow = window
        } else {
            let size = ApplicationAudioEffectMetrics.size
            effectWindow = ApplicationAudioEffectWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            effectWindow.isReleasedWhenClosed = false
            effectWindow.setContentSize(size)
            effectWindow.center()
            effectWindow.delegate = self
            window = effectWindow
        }

        currentApplicationID = applicationID
        effectWindow.title = L10n.text("音效", language: AppSettings.shared.resolvedLanguage)
        let rootView = ApplicationAudioEffectView(
            model: model,
            applicationID: applicationID,
            appName: appName,
            applicationURL: applicationURL
        )
        let host = NSHostingController(rootView: rootView)
        host.sizingOptions = []
        host.view.setFrameSize(ApplicationAudioEffectMetrics.size)
        effectWindow.contentViewController = host
        effectWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        effectWindow.makeFirstResponder(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        if let currentApplicationID {
            model.setApplicationAudioEffectBypassed(false, for: currentApplicationID)
        }
        currentApplicationID = nil
    }
}
