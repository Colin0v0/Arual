import SwiftUI
import Testing
@testable import Aural

struct PanelVolumeSliderTests {
    @Test func pointerMapsToActualTrackAndClampsOutsideDrags() {
        #expect(PanelSliderMetrics.value(at: 3, width: 206) == 0)
        #expect(PanelSliderMetrics.value(at: 103, width: 206) == 0.5)
        #expect(PanelSliderMetrics.value(at: 203, width: 206) == 1)
        #expect(PanelSliderMetrics.value(at: -100, width: 206) == 0)
        #expect(PanelSliderMetrics.value(at: 300, width: 206) == 1)
    }

    @Test @MainActor func levelMeterIsWiderAndShorter() throws {
        let renderer = ImageRenderer(content: ApplicationLevelMeter(level: 0.8, applicationName: "测试应用"))
        let image = try #require(renderer.nsImage)
        #expect(image.size == CGSize(width: 10, height: 20))
    }

    @Test @MainActor func thinVisualTrackKeepsFullInteractionHeight() throws {
        let renderer = ImageRenderer(content:
            PanelVolumeSlider(value: .constant(0.5), label: "音量测试").frame(width: 180)
        )
        let image = try #require(renderer.nsImage)
        #expect(image.size == CGSize(width: 180, height: 26))
    }
}
