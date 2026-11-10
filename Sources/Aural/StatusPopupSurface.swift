import AppKit
import SwiftUI

/// 菜单栏下方直接显示圆角矩形，不绘制箭头，也不为箭头保留空白高度。
enum StatusPopupMetrics {
    static let cornerRadius: CGFloat = 12
    static let screenInset: CGFloat = 8
    static let topGap: CGFloat = 4

    /// 顶边固定在状态栏下方，底边留出屏幕间距；兼容副屏与负坐标屏幕。
    static func availableHeight(statusItem: CGRect, screen: CGRect) -> CGFloat {
        floor(statusItem.minY - topGap - screen.minY - screenInset)
    }

    static func openingFrame(statusItem: CGRect, screen: CGRect, contentSize: CGSize) -> CGRect {
        let x = min(max(statusItem.midX - contentSize.width / 2, screen.minX + screenInset),
                    screen.maxX - screenInset - contentSize.width)
        return CGRect(x: x, y: statusItem.minY - topGap - contentSize.height,
                      width: contentSize.width, height: contentSize.height)
    }

    static func frame(topLeft: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
    }
}

/// 打开和关闭不参与窗口动画；高度调整仅由主动切页的尺寸动画负责。
final class StatusPopupPanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismiss?() }

    /// 对应 Magpie 的 tintPanel：底色由窗口自己的图层持续绘制，
    /// 透明页面只负责内容，窗口每帧改变底边时不会等 SwiftUI 补背景。
    func installNativeBackdrop() {
        guard let contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = PanelStyle.canvasNSColor(for: effectiveAppearance).cgColor
        contentView.layer?.cornerRadius = StatusPopupMetrics.cornerRadius
        contentView.layer?.masksToBounds = true
    }

    func presentImmediately(frame: CGRect) {
        animationBehavior = .none
        alphaValue = 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            setFrame(frame, display: false, animate: false)
            contentView?.layoutSubtreeIfNeeded()
            makeKeyAndOrderFront(nil)
        }
    }
}

struct StatusPopupSurface<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                RoundedRectangle(cornerRadius: StatusPopupMetrics.cornerRadius)
                    .strokeBorder(PanelStyle.line, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}
