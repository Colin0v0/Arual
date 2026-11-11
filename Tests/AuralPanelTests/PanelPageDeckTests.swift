import AppKit
import SwiftUI
import Testing
@testable import Aural

struct PanelPageDeckTests {
    @Test @MainActor func rapidSwitchingKeepsTheSameNaturalHeight() {
        let state = DeckState()
        let host = NSHostingView(rootView: DeckFixture(state: state))
        host.frame.size = host.fittingSize
        PanelTestSupport.flushLayout(host)
        #expect(host.fittingSize == NSSize(width: PanelMetrics.width, height: 260))
        let originalFrame = host.frame
        for index in 0..<80 {
            state.selection = index % 2
            PanelTestSupport.flushLayout(host)
            // 短页和长页来回切换，不能产生短页高度、中间帧高度或宽度波动。
            #expect(host.fittingSize == NSSize(width: PanelMetrics.width, height: 260))
            #expect(host.frame == originalFrame)
        }
    }

    @Test @MainActor func realContentChangesUpdateSharedHeightNotSelection() {
        let state = DeckState()
        let host = NSHostingView(rootView: DeckFixture(state: state))
        host.frame.size = host.fittingSize
        state.longPageHeight = 330
        PanelTestSupport.flushLayout(host)
        #expect(host.fittingSize.height == 330)
        state.selection = 1
        PanelTestSupport.flushLayout(host)
        #expect(host.fittingSize.height == 330)
        state.longPageHeight = 210
        PanelTestSupport.flushLayout(host)
        #expect(host.fittingSize.height == 210)
    }

    @Test @MainActor func eachPageRetainsItsOwnScrollPosition() throws {
        let state = DeckState()
        let host = NSHostingView(rootView: ViewportFixture(state: state))
        host.frame.size = NSSize(width: PanelMetrics.width, height: 200)
        PanelTestSupport.flushLayout(host)
        let scrolls = findScrollViews(in: host)
        #expect(scrolls.count == 2)
        for scroll in scrolls {
            #expect(!scroll.hasVerticalScroller)
            #expect(!scroll.hasHorizontalScroller)
            #expect(scroll.autohidesScrollers)
            #expect(scroll.scrollerStyle == .overlay)
        }
        let first = try #require(scrolls.first)
        let second = try #require(scrolls.last)
        first.contentView.scroll(to: NSPoint(x: 0, y: 120))
        second.contentView.scroll(to: NSPoint(x: 0, y: 60))
        for index in 0..<30 {
            state.selection = index % 2
            PanelTestSupport.flushLayout(host)
            #expect(first.contentView.bounds.origin.y == 120)
            #expect(second.contentView.bounds.origin.y == 60)
            #expect(host.frame.size == NSSize(width: PanelMetrics.width, height: 200))
        }
        #expect(state.heightSnapshots.last == [0: 450, 1: 300])
    }

    @Test @MainActor func hiddenPageGrowthUpdatesOnlyItsOwnMeasurement() {
        let state = DeckState()
        let host = NSHostingView(rootView: ViewportFixture(state: state))
        host.frame.size = NSSize(width: PanelMetrics.width, height: 200)
        PanelTestSupport.flushLayout(host)
        #expect(state.heightSnapshots.last == [0: 450, 1: 300])
        state.secondPageHeight = 900
        PanelTestSupport.flushLayout(host)
        #expect(state.heightSnapshots.last == [0: 450, 1: 900])
        #expect(host.frame.height == 200)
        state.selection = 1
        PanelTestSupport.flushLayout(host)
        #expect(state.heightSnapshots.last == [0: 450, 1: 900])
    }

    @Test @MainActor func hiddenPageCannotReceiveKeyboardButtonActions() throws {
        let host = NSHostingView(rootView:
            PanelPageDeck(items: [0, 1], selection: 0) { item in
                PanelActionButton(item == 0 ? "刷新" : "断开", action: {})
            }.frame(width: 100)
        )
        host.frame.size = host.fittingSize
        PanelTestSupport.flushLayout(host)
        func buttons(in view: NSView) -> [PanelActionControl] {
            if let button = view as? PanelActionControl { return [button] }
            return view.subviews.flatMap { buttons(in: $0) }
        }
        let controls = buttons(in: host)
        let visible = try #require(controls.first { $0.title == "刷新" })
        let hidden = try #require(controls.first { $0.title == "断开" })
        #expect(visible.isEnabled)
        #expect(!hidden.isEnabled)
    }

    @Test @MainActor func resizingViewportCannotRevealScrollbars() {
        let state = DeckState()
        let host = NSHostingView(rootView: ViewportFixture(state: state))
        host.frame.size = CGSize(width: PanelMetrics.width, height: state.viewportHeight)
        PanelTestSupport.flushLayout(host)
        for height: CGFloat in [186, 220, 260, 310, 350, 310, 260, 220, 186] {
            state.viewportHeight = height
            host.frame.size = CGSize(width: PanelMetrics.width, height: height)
            PanelTestSupport.flushLayout(host)
            let scrolls = findScrollViews(in: host)
            #expect(scrolls.count == 2)
            for scroll in scrolls {
                #expect(!scroll.hasVerticalScroller)
                #expect(!scroll.hasHorizontalScroller)
                #expect(scroll.scrollerStyle == .overlay)
            }
        }
    }

    @Test @MainActor func nativePolicyHidesLegacyScrollbarsWithoutDisablingScrolling() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        scroll.scrollerStyle = .legacy
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        scroll.documentView = document
        let policy = PanelScrollPolicyView(frame: document.bounds)
        document.addSubview(policy)
        policy.layoutSubtreeIfNeeded()
        #expect(!scroll.hasVerticalScroller)
        #expect(!scroll.hasHorizontalScroller)
        #expect(scroll.autohidesScrollers)
        #expect(scroll.scrollerStyle == .overlay)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        #expect(scroll.contentView.bounds.origin.y == 120)
        #expect(policy.hitTest(.zero) == nil)
    }

    @Test func motionStaysShortAndRespectsReduceMotion() {
        #expect(PanelStyle.tabAnimation(reduceMotion: true) == nil)
        #expect(PanelStyle.tabAnimation(reduceMotion: false) != nil)
        #expect(PanelStyle.tabDuration <= 0.1)
        #expect(PanelStyle.resizeDuration <= 0.18)
    }

    @MainActor private final class DeckState: ObservableObject {
        @Published var selection = 0
        @Published var viewportHeight: CGFloat = 200
        @Published var longPageHeight: CGFloat = 260
        @Published var secondPageHeight: CGFloat = 300
        var heightSnapshots: [[Int: CGFloat]] = []
    }

    private struct DeckFixture: View {
        @ObservedObject var state: DeckState
        var body: some View {
            PanelPageDeck(items: [0, 1], selection: state.selection) { page in
                Text(page == 0 ? "应用页测试夹具" : "耳机页测试夹具")
                    .frame(height: page == 0 ? 80 : state.longPageHeight, alignment: .top)
            }
            .frame(width: PanelMetrics.width)
            // 几何回归测试关闭时间插值；产品中的动画仍由减少动态效果设置控制。
            .transaction { $0.disablesAnimations = true }
        }
    }

    private struct ViewportFixture: View {
        @ObservedObject var state: DeckState
        var body: some View {
            PanelPageViewport(items: [0, 1], selection: state.selection, height: state.viewportHeight,
                              pageHeightsChanged: { state.heightSnapshots.append($0) }) { page in
                Text(page == 0 ? "应用页滚动测试夹具" : "耳机页滚动测试夹具")
                    .frame(maxWidth: .infinity).frame(height: page == 0 ? 450 : state.secondPageHeight)
            }
            .frame(width: PanelMetrics.width)
            .transaction { $0.disablesAnimations = true }
        }
    }

    @MainActor private func findScrollViews(in view: NSView) -> [NSScrollView] {
        if let scroll = view as? NSScrollView { return [scroll] }
        return view.subviews.flatMap { findScrollViews(in: $0) }
    }
}
