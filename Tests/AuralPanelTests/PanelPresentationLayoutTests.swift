import AppKit
import SwiftUI
import Testing
@testable import Aural

struct PanelPresentationLayoutTests {
    @Test @MainActor func backgroundMeasurementsStayPendingUntilReopen() {
        let layout = PanelPresentationLayout()
        layout.selectPage(0)
        layout.reportPageHeights([0: CGFloat(254)])
        #expect(layout.size == CGSize(width: PanelMetrics.width, height: 368))
        layout.beginPresentation()
        for height: CGFloat in [0, 120, 900, 271.2] {
            layout.reportPageHeights([0: height])
            #expect(layout.size == CGSize(width: PanelMetrics.width, height: 368))
        }
        layout.endPresentation()
        #expect(layout.size.height == 386)
        layout.beginPresentation()
        layout.reportPageHeights([0: CGFloat(900)])
        layout.beginPresentation()
        layout.selectPage(0) // 当前页重复点击不允许后台新高度混入。
        #expect(layout.size.height == 386)
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
        layout.requestSelectedPageResize()
        layout.reportPageHeights(["output": CGFloat(420)])
        #expect(layout.size.height == 534)

        layout.requestSelectedPageResize()
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
        #expect(layout.size.height == 334)
    }

    @Test @MainActor func backgroundGrowthIsDeferredButSwitchingStillAdapts() {
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
        #expect(layout.size.height == 674) // 停留时后台变短也不让窗口突然收缩。

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
