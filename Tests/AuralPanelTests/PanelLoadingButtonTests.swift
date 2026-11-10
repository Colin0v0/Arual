import AppKit
import SwiftUI
import Testing
@testable import Aural

struct PanelLoadingButtonTests {
    @Test @MainActor func loadingReplacesTitleInsideOriginalButtonBounds() throws {
        let state = LoadingState()
        let host = NSHostingView(rootView: LoadingFixture(state: state))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let button = try #require(findButton(in: host))
        let frame = button.convert(button.bounds, to: host)
        let titleSize = PanelActionMetrics.textSize("刷新")
        #expect(button.bounds.size == titleSize)
        #expect(button.isEnabled)

        for _ in 0..<3 {
            state.loading = true
            host.layoutSubtreeIfNeeded()
            button.layoutSubtreeIfNeeded()
            let spinner = try #require(button.subviews.compactMap { $0 as? NSProgressIndicator }.first)
            #expect(button.isLoading)
            #expect(button.title.isEmpty)
            #expect(button.attributedTitle.string.isEmpty)
            #expect((button.cell as? NSButtonCell)?.title.isEmpty == true)
            #expect(button.intrinsicContentSize == titleSize)
            #expect(!button.isEnabled)
            #expect(button.alphaValue == 1) // 禁止重复点击，但加载圈不跟着禁用状态变灰。
            #expect(!spinner.isHidden)
            #expect(spinner.frame.size == CGSize(width: 14, height: 14))
            #expect(spinner.frame.midX == button.bounds.midX)
            #expect(spinner.frame.midY == button.bounds.midY)
            #expect(button.convert(button.bounds, to: host) == frame)
            #expect(button.bounds.size == titleSize)
            #expect(host.fittingSize == CGSize(width: titleSize.width, height: titleSize.height))
            #expect(button.layer?.backgroundColor == NSColor(PanelStyle.controlHover).cgColor)
            // 模拟模型刷新再次设置内容和禁用样式，文字也不能重新出现。
            button.setContent(.text("刷新"))
            button.isEnabled = false
            button.highlight(true)
            #expect(button.title.isEmpty)
            #expect((button.cell as? NSButtonCell)?.title.isEmpty == true)
            #expect(button.intrinsicContentSize == titleSize)

            state.loading = false
            host.layoutSubtreeIfNeeded()
            #expect(!button.isLoading)
            #expect(button.isEnabled)
            #expect(spinner.isHidden)
            #expect(button.title == "刷新")
            #expect(button.convert(button.bounds, to: host) == frame)
        }
    }

    @MainActor private final class LoadingState: ObservableObject {
        @Published var loading = false
    }

    private struct LoadingFixture: View {
        @ObservedObject var state: LoadingState
        var body: some View {
            PanelActionButton("刷新", isLoading: state.loading, action: {})
        }
    }

    @MainActor private func findButton(in view: NSView) -> PanelActionControl? {
        if let button = view as? PanelActionControl { return button }
        for child in view.subviews {
            if let button = findButton(in: child) { return button }
        }
        return nil
    }
}
