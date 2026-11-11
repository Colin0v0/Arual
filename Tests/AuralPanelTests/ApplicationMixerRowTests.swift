import AppKit
import SwiftUI
import Testing
import AuralCore
@testable import Aural

struct ApplicationMixerRowTests {
    @Test @MainActor func fullRowStaysSingleLineWithMeterAndPercentage() throws {
        let image = try renderRow(state: ApplicationMixState(), level: 0.8)
        #expect(image.size.width == PanelMetrics.width - 24)
        #expect(image.size.height <= 46)
    }

    @Test @MainActor func longFailureDoesNotCreateAnExtraTextRow() throws {
        var state = ApplicationMixState()
        state.enable(outputUID: "test-output")
        state.fail("录制权限尚未允许，请在系统设置中检查屏幕与系统音频录制权限。")
        let image = try renderRow(state: state, level: nil)
        #expect(image.size.height <= 46)
    }

    @Test @MainActor func hoverStateRendersAroundTheWholeApplicationRow() throws {
        var state = ApplicationMixState()
        state.enable(outputUID: "test-output")
        let levelSource = ApplicationLevelSource()
        levelSource.update(0.6)
        let app = try #require(applicationFixture())
        let row = ApplicationMixerRow(app: app, state: state,
                                      levelSource: levelSource, metersVisible: true,
                                      awaitingStream: false, status: "正在应用音量",
                                      toggleMute: {}, setGain: { _ in },
                                      retryMeter: {}, applyConfiguration: {},
                                      stopManaging: {}, initiallyHovered: true)
            .frame(width: PanelMetrics.width - 24)
            .background(PanelStyle.canvas)
            .preferredColorScheme(.light)
        let host = NSHostingView(rootView: row)
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/aural-application-row-hover-light.png"))
    }

    @MainActor private func renderRow(state: ApplicationMixState, level: Float?) throws -> NSImage {
        // 明确的测试夹具，不进入产品数据源，不请求权限或建立 tap。
        let app = try #require(applicationFixture())
        let levelSource = ApplicationLevelSource()
        levelSource.update(level)
        let row = ApplicationMixerRow(app: app, state: state,
                                      levelSource: levelSource, metersVisible: true,
                                      awaitingStream: false,
                                      status: "测试布局", toggleMute: {}, setGain: { _ in },
                                      retryMeter: {}, applyConfiguration: {}, stopManaging: {})
            .font(PanelStyle.bodyFont)
            .frame(width: PanelMetrics.width - 24)
            .background(PanelStyle.canvas)
            .preferredColorScheme(.light)
        // 原生按钮不能由 ImageRenderer 展平；使用实际宿主，连同真实点击范围一起验收。
        let host = NSHostingView(rootView: row)
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        var actionCount = 0
        func validateControls(_ view: NSView) {
            if let button = view as? PanelActionControl {
                actionCount += 1
                #expect(button.hoverStyle == .foregroundOnly)
                let rect = button.convert(button.bounds, to: host)
                #expect(button.bounds.size == PanelActionMetrics.square)
                #expect(rect.minX >= 0)
                #expect(rect.maxX <= host.bounds.width)
            }
            if let slider = view as? NSSlider {
                #expect(slider.bounds.width >= 60)
            }
            view.subviews.forEach(validateControls)
        }
        validateControls(host)
        #expect(actionCount == 1) // 只剩静音按钮，不保留可见的三个点入口。
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        if state.failure == nil {
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/aural-application-row-layout.png"))
        }
        return image
    }

    @MainActor private func applicationFixture() -> ApplicationAudioRow? {
        ApplicationCatalog.rows(
            applications: [RunningApplicationInfo(processID: 1, bundleID: "test.music",
                                                  name: "网易云音乐", bundleURL: nil)],
            records: [], executableURLs: [:]
        ).first
    }
}
