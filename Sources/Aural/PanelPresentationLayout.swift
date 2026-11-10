import SwiftUI

/// 每个页面记录自己的自然高度。只有打开窗口、用户主动切页或展开内容才采纳新尺寸，
/// 停留期间的异步状态只更新测量记录，不悄悄撑高窗口。
@MainActor
final class PanelPresentationLayout: ObservableObject {
    @Published private(set) var size = PanelMetrics.size(contentHeight: 0)
    private var pendingSize = PanelMetrics.size(contentHeight: 0)
    private var pageHeights: [AnyHashable: CGFloat] = [:]
    private var selectedPage: AnyHashable?
    private var awaitingSelectedPageMeasurement = false
    private var awaitingUserResize = false
    private(set) var shouldAnimateResize = false
    private(set) var isPresented = false

    var viewportHeight: CGFloat { size.height - PanelMetrics.chromeHeight }

    func reportPageHeights<Page: Hashable>(_ heights: [Page: CGFloat]) {
        for (page, height) in heights { pageHeights[AnyHashable(page)] = height }
        guard let selectedPage, let height = pageHeights[selectedPage] else { return }
        pendingSize = PanelMetrics.size(contentHeight: height)
        if !isPresented || awaitingSelectedPageMeasurement {
            let animate = isPresented && awaitingUserResize
            awaitingSelectedPageMeasurement = false
            awaitingUserResize = false
            applyPendingSize(animated: animate)
        }
    }

    /// 只由主动切换调用。同页重复点击不采纳后台新高度，防止再次出现静默增长。
    func selectPage<Page: Hashable>(_ page: Page) {
        let key = AnyHashable(page)
        guard key != selectedPage else { return }
        let userInitiated = isPresented && selectedPage != nil
        selectedPage = key
        if let height = pageHeights[key] {
            awaitingSelectedPageMeasurement = false
            awaitingUserResize = false
            pendingSize = PanelMetrics.size(contentHeight: height)
            applyPendingSize(animated: userInitiated)
        } else {
            // 新页面尚未布局时保留当前外框，等本页第一次真实测量，不先缩到零或最小高度。
            awaitingSelectedPageMeasurement = true
            awaitingUserResize = userInitiated
        }
    }

    /// 展开列表等主动操作会改变当前页高度，下一次测量到达时立即撑开或收起外框。
    func requestSelectedPageResize() {
        guard selectedPage != nil else { return }
        awaitingSelectedPageMeasurement = true
        awaitingUserResize = isPresented
    }

    func beginPresentation() {
        guard !isPresented else { return }
        shouldAnimateResize = false
        applyPendingSize(animated: false)
        isPresented = true
    }

    func endPresentation() {
        isPresented = false
        shouldAnimateResize = false
        applyPendingSize(animated: false)
    }

    private func applyPendingSize(animated: Bool) {
        guard size != pendingSize else { return }
        // 初次展示、补齐初始测量都直接设置；只有用户切页才启动尺寸动画。
        shouldAnimateResize = animated
        size = pendingSize
    }
}
