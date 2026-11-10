import AppKit
import SwiftUI
import Testing
@testable import Aural

struct PanelPresentationLayoutTests {
    @Test @MainActor func visibleContentGrowthAndShrinkResizeWithoutReopening() {
        let layout = PanelPresentationLayout()
        layout.selectPage(0)
        layout.reportPageHeights([0: CGFloat(254)])
        layout.beginPresentation()

        // APP 行增减、错误提示出现/消失都来自自然测量，不应要求用户再点一次或重开窗口。
        for height: CGFloat in [300, 254, 420, 200, 271.2] {
            layout.reportPageHeights([0: height])
            #expect(layout.size == PanelMetrics.size(contentHeight: height))
            #expect(!layout.shouldAnimateResize)
        }
        let size = layout.size
        layout.endPresentation()
        layout.beginPresentation()
        #expect(layout.size == size)
    }

    @Test @MainActor func hiddenMeasurementsNeverResizeVisiblePage() {
        let layout = PanelPresentationLayout()
        layout.selectPage(0)
        layout.reportPageHeights([0: CGFloat(254), 1: 180])
        layout.beginPresentation()
        for height: CGFloat in [220, 900, 120] {
            layout.reportPageHeights([1: height])
            #expect(layout.size.height == 368)
        }
        layout.selectPage(1)
        #expect(layout.size.height == 300)
    }

    @Test @MainActor func explicitSelectionUsesEachPagesOwnHeight() {
        let layout = PanelPresentationLayout()
        layout.selectPage("output")
        layout.reportPageHeights(["output": CGFloat(360), "headphones": 180, "input": 220])
        layout.beginPresentation()
        #expect(layout.size.height == 474)
        layout.selectPage("headphones")
        #expect(layout.size.height == 300)
        layout.selectPage("input")
        #expect(layout.size.height == 334)
        layout.selectPage("output")
        #expect(layout.size == CGSize(width: PanelMetrics.width, height: 474))
    }

    @Test @MainActor func explicitContentExpansionResizesThePresentedPanel() {
        let layout = PanelPresentationLayout()
        layout.selectPage("output")
        layout.reportPageHeights(["output": CGFloat(254)])
        layout.beginPresentation()
        #expect(layout.size.height == 368)

        // 展开设备筛选属于用户主动操作，新测量到达后必须直接改变外框高度。
        layout.reportPageHeights(["output": CGFloat(420)])
        #expect(layout.size.height == 534)

        layout.reportPageHeights(["output": CGFloat(200)])
        #expect(layout.size.height == 314)
    }

    @Test @MainActor func unknownPageWaitsForItsOwnMeasurementWithoutIntermediateCollapse() {
        let layout = PanelPresentationLayout()
        layout.selectPage(0)
        layout.reportPageHeights([0: CGFloat(254)])
        layout.beginPresentation()
        layout.selectPage(1)
        #expect(layout.size.height == 368)
        layout.reportPageHeights([0: CGFloat(900)])
        #expect(layout.size.height == 368)
        layout.reportPageHeights([1: CGFloat(220)])
        #expect(layout.size.height == 334)
        layout.reportPageHeights([1: CGFloat(900)])
        #expect(layout.size.height == 674)
    }

    @Test @MainActor func hostedVisibleContentAdaptsButHiddenContentCannotChangeTheWindow() {
        let state = PresentationState()
        let layout = PanelPresentationLayout()
        layout.selectPage(0)
        let host = NSHostingView(rootView: PresentationFixture(state: state, layout: layout))
        host.frame.size = layout.size
        host.layoutSubtreeIfNeeded()
        #expect(layout.size.height == 368)
        host.frame.size = layout.size
        host.layoutSubtreeIfNeeded()
        layout.beginPresentation()
        let originalFrame = host.frame
        let notificationCount = state.reportedSizes.count

        state.headphoneHeight = 900
        host.layoutSubtreeIfNeeded()
        #expect(layout.size == originalFrame.size)
        #expect(host.frame == originalFrame)
        #expect(state.reportedSizes.count == notificationCount)

        layout.selectPage(1)
        state.selection = 1
        host.frame.size = layout.size
        host.layoutSubtreeIfNeeded()
        #expect(layout.size.height == 674)
        state.headphoneHeight = 180
        host.layoutSubtreeIfNeeded()
        #expect(layout.size.height == 300) // 当前页变短时立即收起，不保留多余空白。

        for index in 0..<30 {
            let page = index % 2
            layout.selectPage(page)
            state.selection = page
            host.frame.size = layout.size
            host.layoutSubtreeIfNeeded()
            #expect(layout.size.height == (page == 0 ? 368 : 300))
            #expect(host.frame.width == PanelMetrics.width)
        }

        let sizeEvents = state.reportedSizes.count
        // 模拟原生外框动画的中间尺寸；这些尺寸不能反过来改变目标高度。
        for height: CGFloat in [430, 400, 360, 320, 300] {
            host.frame.size = CGSize(width: PanelMetrics.width, height: height)
            host.layoutSubtreeIfNeeded()
            #expect(layout.size.height == 300)
        }
        #expect(state.reportedSizes.count == sizeEvents)
    }

    @Test @MainActor func openingAndClosingNeverCarryOverPageResizeAnimation() {
        let layout = PanelPresentationLayout()
        layout.selectPage(0)
        layout.reportPageHeights([0: CGFloat(254), 1: 180])
        layout.beginPresentation()
        #expect(!layout.shouldAnimateResize)
        layout.selectPage(1)
        #expect(layout.shouldAnimateResize)
        layout.endPresentation()
        #expect(!layout.shouldAnimateResize)
        layout.beginPresentation()
        #expect(!layout.shouldAnimateResize)
        layout.selectPage(0)
        #expect(layout.shouldAnimateResize)
    }

    @Test @MainActor func lateInitialMeasurementIsInstantButExplicitNewPageCanAnimate() {
        let layout = PanelPresentationLayout()
        layout.beginPresentation()
        layout.selectPage(0)
        layout.reportPageHeights([0: CGFloat(254)])
        #expect(layout.size.height == 368)
        #expect(!layout.shouldAnimateResize)
        layout.selectPage(1)
        layout.reportPageHeights([1: CGFloat(220)])
        #expect(layout.size.height == 334)
        #expect(layout.shouldAnimateResize)
    }

    @Test @MainActor func shrinkingHostedContentClearsObsoleteScrollOffset() throws {
        let state = PresentationState()
        state.applicationHeight = 1_200
        let layout = PanelPresentationLayout()
        layout.setAvailableHeight(900)
        layout.selectPage(0)
        let host = NSHostingView(rootView: PresentationFixture(state: state, layout: layout))

        func settle() {
            // 宿主先上报自然内容，再按目标外框完成布局；不把旧视口高度当作测量结果。
            for _ in 0..<3 {
                host.frame.size = layout.size
                host.layoutSubtreeIfNeeded()
            }
        }
        func scrollViews(in view: NSView) -> [NSScrollView] {
            if let scroll = view as? NSScrollView { return [scroll] }
            return view.subviews.flatMap { scrollViews(in: $0) }
        }
        settle()
        layout.beginPresentation()
        #expect(layout.size.height == 900)
        let scroll = try #require(scrollViews(in: host).first)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        #expect(scroll.contentView.bounds.origin.y == 200)

        state.applicationHeight = 254
        settle()
        #expect(layout.size.height == 368)
        #expect(scroll.contentView.bounds.origin.y == 0)
        let document = try #require(scroll.documentView)
        #expect(document.frame.height <= scroll.contentView.bounds.height)

        // 增加 APP 行不需要关掉重开；空间足够时也没有内部滚动距离。
        state.applicationHeight = 700
        settle()
        #expect(layout.size.height == 814)
        #expect(document.frame.height <= scroll.contentView.bounds.height)
    }

    @Test @MainActor func screenBudgetControlsScrollingInsteadOfTheOldFixedCap() {
        let layout = PanelPresentationLayout()
        layout.setAvailableHeight(900)
        layout.selectPage(0)
        layout.reportPageHeights([0: CGFloat(700)])
        layout.beginPresentation()
        #expect(layout.size.height == 814)
        #expect(layout.viewportHeight == 700)

        layout.reportPageHeights([0: CGFloat(1_200)])
        #expect(layout.size.height == 900)
        layout.setAvailableHeight(500)
        #expect(layout.size.height == 500)
        // 缩短至可容纳后恢复自然高度，不沿用先前的长页滚动视口。
        layout.reportPageHeights([0: CGFloat(220)])
        #expect(layout.size.height == 334)
        layout.setAvailableHeight(280)
        #expect(layout.size.height == 280)
    }

    @Test @MainActor func hiddenReportBetweenExpansionAndCollapseCannotSwallowTheNewHeight() {
        let layout = PanelPresentationLayout()
        layout.selectPage(0)
        layout.reportPageHeights([0: CGFloat(250), 1: 180])
        layout.beginPresentation()
        // 模拟收起列表时隐藏页先上报；旧实现会用旧高度消耗一次性改高标志。
        for _ in 0..<20 {
            layout.reportPageHeights([1: CGFloat(220)])
            layout.reportPageHeights([0: CGFloat(420)])
            #expect(layout.size.height == 534)
            layout.reportPageHeights([1: CGFloat(180)])
            layout.reportPageHeights([0: CGFloat(250)])
            #expect(layout.size.height == 364)
        }
    }

    @MainActor private final class PresentationState: ObservableObject {
        @Published var selection = 0
        @Published var applicationHeight: CGFloat = 254
        @Published var headphoneHeight: CGFloat = 180
        var reportedSizes: [CGSize] = []
    }

    private struct PresentationFixture: View {
        @ObservedObject var state: PresentationState
        @ObservedObject var layout: PanelPresentationLayout
        var body: some View {
            GeometryReader { container in
                VStack(spacing: 0) {
                    Color.clear.frame(height: 80)
                    PanelPageViewport(items: [0, 1], selection: state.selection,
                                      height: max(0, container.size.height - PanelMetrics.chromeHeight),
                                      pageHeightsChanged: layout.reportPageHeights) { page in
                        Text(page == 0 ? "APP 页高度测试" : "耳机页异步错误测试")
                            .frame(maxWidth: .infinity)
                            .frame(height: page == 0 ? state.applicationHeight : state.headphoneHeight)
                    }
                    Color.clear.frame(height: 34)
                }
            }
            .frame(width: PanelMetrics.width)
            .onChange(of: layout.size, initial: true) { _, size in state.reportedSizes.append(size) }
            .transaction { $0.disablesAnimations = true }
        }
    }
}
