import Foundation
import Testing
@testable import Aural

struct PanelMetricsTests {
    @Test func firstLayoutAndEmptyContentHaveMinimumHeight() {
        #expect(PanelMetrics.size(contentHeight: 0) == CGSize(width: PanelMetrics.width, height: 300))
        #expect(PanelMetrics.width == 440)
        #expect(PanelMetrics.size(contentHeight: 120).height == 300)
    }

    @Test func contentGrowsWithinCapThenScrolls() {
        #expect(PanelMetrics.size(contentHeight: 220).height == 334)
        #expect(PanelMetrics.size(contentHeight: 560).height == 674)
        #expect(PanelMetrics.size(contentHeight: 1_000).height == 674)
    }

    @Test func screenBudgetLetsLongContentGrowBeyondTheOldCap() {
        #expect(PanelMetrics.size(contentHeight: 700, maximumHeight: 900).height == 814)
        #expect(PanelMetrics.size(contentHeight: 1_000, maximumHeight: 900).height == 900)
        #expect(PanelMetrics.size(contentHeight: 100, maximumHeight: 280).height == 280)
    }

    @Test func contentCanShrinkBackWithoutChangingChrome() {
        for height: CGFloat in [0, 120, 220, 560, 1_000, 120] {
            let viewport = PanelMetrics.viewportHeight(contentHeight: height)
            let size = PanelMetrics.size(contentHeight: height)
            #expect(size.height - viewport == 114)
            #expect((300...674).contains(size.height))
        }
    }

    @Test func fractionalLayoutUsesWholePointBounds() {
        #expect(PanelMetrics.size(contentHeight: 220.25).height == 335)
    }

    @Test func windowResizePreservesTopLeftWithoutHorizontalDrift() {
        var frame = CGRect(x: 925, y: 432, width: 420, height: 300)
        let originalTopLeft = CGPoint(x: frame.minX, y: frame.maxY)
        for height: CGFloat in [334, 464, 300, 464, 335, 300] {
            frame = PanelMetrics.resizedWindowFrame(frame, size: CGSize(width: 420, height: height))
            #expect(frame.minX == originalTopLeft.x)
            #expect(frame.maxY == originalTopLeft.y)
            #expect(frame.size == CGSize(width: 420, height: height))
        }
    }

}
