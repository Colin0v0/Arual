import SwiftUI

/// 每页独立缓存自然高度；当前页的内容增减立即调整外框，隐藏页只更新自己的缓存。
/// 只发布取整后的目标尺寸，不把原生窗口动画中的中间高度当成新的内容高度。
@MainActor
final class PanelPresentationLayout: ObservableObject {
    @Published private(set) var size = PanelMetrics.size(contentHeight: 0)
    private var pageHeights: [AnyHashable: CGFloat] = [:]
    private var selectedPage: AnyHashable?
    private var maximumHeight = PanelMetrics.chromeHeight + PanelMetrics.maximumContentHeight
    private var awaitingUserResize = false
    private(set) var shouldAnimateResize = false
    private(set) var isPresented = false

    var viewportHeight: CGFloat { size.height - PanelMetrics.chromeHeight }

    func reportPageHeights<Page: Hashable>(_ heights: [Page: CGFloat]) {
        for (page, height) in heights { pageHeights[AnyHashable(page)] = height }
        // 隐藏页的测量不能消耗当前页的待测量状态，也不能拿当前页的旧缓存触发改高。
        guard let selectedPage, heights.keys.contains(where: { AnyHashable($0) == selectedPage }) else { return }
        let animate = isPresented && awaitingUserResize
        awaitingUserResize = false
        applySelectedPageSize(animated: animate)
    }

    /// 切页使用该页自己的自然高度；首次布局尚未测量时，保持外框直到真实测量到达。
    func selectPage<Page: Hashable>(_ page: Page) {
        let key = AnyHashable(page)
        guard key != selectedPage else { return }
        let userInitiated = isPresented && selectedPage != nil
        selectedPage = key
        awaitingUserResize = userInitiated && pageHeights[key] == nil
        applySelectedPageSize(animated: userInitiated)
    }

    /// 菜单栏控制器按实际屏幕及固定顶边提供可用高度；只有装不下时才需要内部滚动。
    func setAvailableHeight(_ height: CGFloat) {
        precondition(height.isFinite && height >= PanelMetrics.chromeHeight)
        maximumHeight = floor(height)
        applySelectedPageSize(animated: false)
    }

    func beginPresentation() {
        guard !isPresented else { return }
        shouldAnimateResize = false
        awaitingUserResize = false
        applySelectedPageSize(animated: false)
        isPresented = true
    }

    func endPresentation() {
        isPresented = false
        shouldAnimateResize = false
        awaitingUserResize = false
    }

    private func applySelectedPageSize(animated: Bool) {
        guard let selectedPage, let height = pageHeights[selectedPage] else { return }
        let target = PanelMetrics.size(contentHeight: height, maximumHeight: maximumHeight)
        guard size != target else { return }
        // 自动增减直接落位，避免 APP 播放状态变化附带弹簧动画；主动切页仍保留短动画。
        shouldAnimateResize = animated
        size = target
    }
}
