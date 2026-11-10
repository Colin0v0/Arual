import AppKit
import SwiftUI
import Testing
@testable import Aural

/// 用真实主循环检查切页过程，不把动画全关掉以后只看最终尺寸。
struct PanelPageMotionTests {
    @Test @MainActor func pageTopDoesNotMoveWhileTheNativeViewportResizes() throws {
        _ = NSApplication.shared
        let state = MotionState()
        // 使用产品里相同的 HostingController + 圆角浮层，不只检查裸 NSHostingView。
        let controller = NSHostingController(rootView: StatusPopupSurface { MotionFixture(state: state) })
        controller.sizingOptions = []
        let host = controller.view
        host.frame = CGRect(x: 0, y: 0, width: PanelMetrics.width, height: 464)
        let window = StatusPopupPanel(contentRect: CGRect(x: 400, y: 300, width: PanelMetrics.width, height: 464),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        host.layoutSubtreeIfNeeded()
        defer { window.close() }
        // 给 NSHostingView 一次正常主循环，避免把尚未挂载的首帧误当作动画。
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let views = markers(in: host)
        let header = try #require(views.first { $0.identifier?.rawValue == "page-header" })
        let footer = try #require(views.first { $0.identifier?.rawValue == "page-footer" })
        let initial = try #require(views.first { $0.identifier?.rawValue == "page-0" })
        let top = initial.convert(initial.bounds, to: host).minY
        #expect(top == 80)
        var samples: [CGFloat] = []
        for selection in [1, 2, 0, 2, 1, 0] {
            state.selection = selection
            let marker = try #require(views.first { $0.identifier?.rawValue == "page-\(selection)" })
            let animator = PanelSizeAnimator()
            let anchor = CGPoint(x: window.frame.minX, y: window.frame.maxY)
            let target = StatusPopupMetrics.frame(topLeft: anchor, size: CGSize(width: PanelMetrics.width, height: [464, 334, 300][selection]))
            animator.resize(window: window, to: target, animated: true)
            for _ in 0..<30 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.012))
                host.layoutSubtreeIfNeeded()
                #expect(abs(window.frame.maxY - anchor.y) < 0.001)
                // 与实际面板一样，顶部工具栏固定，只有底边随原生窗口高度移动。
                #expect(header.convert(header.bounds, to: host).minY == 0)
                #expect(abs(footer.convert(footer.bounds, to: host).maxY - host.bounds.height) < 0.5)
                samples.append(marker.convert(marker.bounds, to: host).minY)
            }
            #expect(window.frame == target)
            animator.cancel()
        }
        #expect(samples.count > 8)
        #expect(samples.allSatisfy { abs($0 - top) < 0.5 })
    }

    @Test @MainActor func pageLayoutDoesNotInheritTheTabAnimation() {
        let state = MotionState()
        let host = NSHostingView(rootView: MotionFixture(state: state))
        host.frame = CGRect(x: 0, y: 0, width: PanelMetrics.width, height: 464)
        host.layoutSubtreeIfNeeded()
        state.animatedLayoutUpdates = 0
        state.layoutUpdates = 0
        for selection in [1, 2, 0, 2, 1, 0] {
            state.selection = selection
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        // 必须确实观察到原生子视图更新，不能因夹具未刷新而空跑通过。
        #expect(state.layoutUpdates > 0)
        #expect(state.animatedLayoutUpdates == 0)
    }

    @MainActor private final class MotionState: ObservableObject {
        @Published var selection = 0
        var animatedLayoutUpdates = 0
        var layoutUpdates = 0
    }

    private struct MotionFixture: View {
        @ObservedObject var state: MotionState
        var body: some View {
            GeometryReader { container in
                VStack(spacing: 0) {
                    Marker(name: "page-header", selection: state.selection, state: state).frame(height: 44)
                    Color.clear.frame(height: 36)
                    PanelPageViewport(items: [0, 1, 2], selection: state.selection,
                                      height: container.size.height - 114, pageHeightsChanged: { _ in }) { page in
                        VStack(spacing: 0) {
                            Marker(name: "page-\(page)", selection: state.selection, state: state).frame(height: 1)
                            Color.gray.frame(height: [349, 219, 179][page])
                        }
                    }
                    Marker(name: "page-footer", selection: state.selection, state: state).frame(height: 34)
                }
            }.frame(width: PanelMetrics.width)
        }
    }

    private struct Marker: NSViewRepresentable {
        let name: String
        let selection: Int
        let state: MotionState
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            view.identifier = NSUserInterfaceItemIdentifier(name)
            return view
        }
        func updateNSView(_ nsView: NSView, context: Context) {
            state.layoutUpdates += 1
            if context.transaction.animation != nil && !context.transaction.disablesAnimations {
                state.animatedLayoutUpdates += 1
            }
        }
    }

    @MainActor private func markers(in view: NSView) -> [NSView] {
        if view.identifier?.rawValue.hasPrefix("page-") == true { return [view] }
        return view.subviews.flatMap { markers(in: $0) }
    }
}
