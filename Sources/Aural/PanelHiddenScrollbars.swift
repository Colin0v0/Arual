import AppKit
import SwiftUI

/// 在 SwiftUI 滚动内容内部配置所属的原生滚动容器。
/// 不改系统偏好，不关闭滚动，只去掉横竖拖动条及其占位。
struct PanelHiddenScrollbars: NSViewRepresentable {
    func makeNSView(context: Context) -> PanelScrollPolicyView {
        let view = PanelScrollPolicyView()
        view.needsLayout = true
        return view
    }

    func updateNSView(_ view: PanelScrollPolicyView, context: Context) {
        view.applyScrollPolicy()
        view.needsLayout = true
    }
}

final class PanelScrollPolicyView: NSView {
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        needsLayout = true
        applyScrollPolicy()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        applyScrollPolicy()
    }

    override func layout() {
        super.layout()
        applyScrollPolicy()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func applyScrollPolicy() {
        // 附着前没有所属容器，附着后的 AppKit 布局生命周期会配置这一个明确的容器。
        guard let scroll = enclosingScrollView else { return }
        if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
        if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
        if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
        if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
    }
}
