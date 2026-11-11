import AppKit

/// 设置窗口保留系统键盘导航；鼠标操作时结束上一次的键盘焦点。
final class SettingsWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            makeFirstResponder(nil)
        }
        super.sendEvent(event)
    }
}
