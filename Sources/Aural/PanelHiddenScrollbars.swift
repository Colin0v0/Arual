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
    private weak var observedDocument: NSView?
    private weak var observedClip: NSClipView?
    private var geometryObservers: [NSObjectProtocol] = []

    deinit {
        for observer in geometryObservers { NotificationCenter.default.removeObserver(observer) }
    }

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
        observeGeometry(of: scroll)
        constrainScrollPosition(in: scroll)
    }

    /// SwiftUI 更新内容和 AppKit 更新视口可能分属两次布局。
    /// 同时监听文档及视口尺寸，不能只在收起按钮的回调里检查一次旧几何。
    private func observeGeometry(of scroll: NSScrollView) {
        guard let document = scroll.documentView else { return }
        let clip = scroll.contentView
        guard observedDocument !== document || observedClip !== clip else { return }
        for observer in geometryObservers { NotificationCenter.default.removeObserver(observer) }
        geometryObservers.removeAll()
        observedDocument = document
        observedClip = clip
        document.postsFrameChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        for view in [document, clip] {
            let observer = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: view, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let scroll = self?.enclosingScrollView else { return }
                    self?.constrainScrollPosition(in: scroll)
                }
            }
            geometryObservers.append(observer)
        }
    }

    private func constrainScrollPosition(in scroll: NSScrollView) {
        guard let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let bounds = clip.bounds
        // 高度变化时只修正越界位置；仍在有效范围内的长页滚动位置不能被清空。
        let origin = NSPoint(
            x: min(max(bounds.minX, document.frame.minX), max(document.frame.minX, document.frame.maxX - bounds.width)),
            y: min(max(bounds.minY, document.frame.minY), max(document.frame.minY, document.frame.maxY - bounds.height))
        )
        guard origin != bounds.origin else { return }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
    }
}
