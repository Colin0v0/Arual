import AppKit

/// macOS 15 的 SwiftUI 更新在下一轮主循环提交；仅触发 AppKit layout 不等于状态已应用。
@MainActor
enum PanelTestSupport {
    static func flushLayout(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        host.layoutSubtreeIfNeeded()
    }

    /// 测试窗口必须位于真实可用屏幕内，否则 AppKit 会避让菜单栏并改变预期动画坐标。
    static func windowFrame(size: CGSize) -> CGRect {
        precondition(!NSScreen.screens.isEmpty, "原生窗口测试需要可用屏幕")
        let screen = NSScreen.screens[0].visibleFrame
        precondition(size.width <= screen.width && size.height + 40 <= screen.height)
        return CGRect(x: screen.midX - size.width / 2, y: screen.maxY - 40 - size.height,
                      width: size.width, height: size.height)
    }
}
