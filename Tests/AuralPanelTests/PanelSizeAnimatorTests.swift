import AppKit
import QuartzCore
import Testing
@testable import Aural

/// 验证真实 NSWindow 的原生动画，而不是手动给自写进度函数喂几个数。
struct PanelSizeAnimatorTests {
    @Test @MainActor func nativeAnimatorUsesSystemFramesWithoutAManualResizeLoop() throws {
        _ = NSApplication.shared
        let window = makeWindow()
        defer { window.close() }
        let animator = PanelSizeAnimator()
        let target = CGRect(x: window.frame.minX, y: window.frame.maxY - 334, width: 510, height: 334)
        animator.resize(window: window, to: target, animated: true)
        // 与 Magpie 一样，先把目标留给宿主完成本轮布局，再在下一轮主线程启动 glide。
        #expect(window.frame.size.height == 464)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        #expect(window.frame == target)
        // 原生 animator proxy 使用两参数 setFrame:display:；不能回到手动逐帧三参数路径。
        #expect(window.manualFrameCalls == 0)
        #expect(window.nativeRequests.count > 2)
        let request = try #require(window.nativeRequests.last)
        #expect(request.frame == target)
    }

    @Test @MainActor func reduceMotionAppliesTargetImmediately() {
        let window = makeWindow()
        defer { window.close() }
        let animator = PanelSizeAnimator()
        let target = CGRect(x: window.frame.minX, y: window.frame.maxY - 300, width: 510, height: 300)
        animator.resize(window: window, to: target, animated: false)
        #expect(window.frame == target)
        #expect(window.manualFrameCalls == 1)
    }

    @Test @MainActor func nativeResizeKeepsTheTopEdgeThroughoutTheMainRunLoop() {
        let window = makeWindow()
        defer { window.close() }
        let animator = PanelSizeAnimator()
        let top = window.frame.maxY
        let target = CGRect(x: window.frame.minX, y: top - 300, width: 510, height: 300)
        animator.resize(window: window, to: target, animated: true)
        var intermediateHeights: [CGFloat] = []
        for _ in 0..<30 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.012))
            #expect(abs(window.frame.maxY - top) < 0.001)
            #expect(window.frame.minX == target.minX)
            #expect(window.frame.width == 510)
            if window.frame.height > 300 && window.frame.height < 464 {
                intermediateHeights.append(window.frame.height)
            }
        }
        #expect(!intermediateHeights.isEmpty)
        #expect(window.frame == target)
    }

    @Test @MainActor func rapidReversalEndsAtTheLatestNativeTarget() {
        let window = makeWindow()
        defer { window.close() }
        let animator = PanelSizeAnimator()
        let top = window.frame.maxY
        animator.resize(window: window, to: CGRect(x: window.frame.minX, y: top - 300, width: 510, height: 300), animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        let target = CGRect(x: window.frame.minX, y: top - 464, width: 510, height: 464)
        animator.resize(window: window, to: target, animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        #expect(window.frame == target)
        #expect(window.manualFrameCalls == 0)
    }

    @Test @MainActor func returningToInitialFrameBeforeFirstAnimationFrameSupersedesOldTarget() {
        let window = makeWindow()
        defer { window.close() }
        let animator = PanelSizeAnimator()
        let original = window.frame
        let shorter = CGRect(x: original.minX, y: original.maxY - 300, width: original.width, height: 300)
        animator.resize(window: window, to: shorter, animated: true)
        // 下一轮提交旧目标后立即回到原始尺寸；CI 可能尚未绘制任何中间帧。
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                animator.resize(window: window, to: original, animated: true)
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        #expect(window.frame == original)
        #expect(window.manualFrameCalls == 0)
        #expect(window.nativeRequests.last?.frame == original)
    }

    @Test @MainActor func cancelStopsAnOldTargetFromResizingTheHiddenPanel() {
        let window = makeWindow()
        defer { window.close() }
        let animator = PanelSizeAnimator()
        let top = window.frame.maxY
        animator.resize(window: window, to: CGRect(x: window.frame.minX, y: top - 300, width: 510, height: 300), animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        animator.cancel()
        let stopped = window.frame
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        #expect(window.frame == stopped)
    }

    @Test @MainActor func cancellingThenReopeningCannotApplyAQueuedOldFrame() {
        let window = makeWindow()
        defer { window.close() }
        let animator = PanelSizeAnimator()
        let top = window.frame.maxY
        animator.resize(window: window, to: CGRect(x: window.frame.minX, y: top - 300, width: 510, height: 300), animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        animator.cancel()
        let reopened = PanelTestSupport.windowFrame(size: CGSize(width: 510, height: 400))
        animator.resize(window: window, to: reopened, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        #expect(window.frame == reopened)
    }

    @Test @MainActor func rapidResizeRequestsOnlySubmitTheLatestNextRunLoopTarget() {
        _ = NSApplication.shared
        let window = makeWindow()
        defer { window.close() }
        let animator = PanelSizeAnimator()
        let top = window.frame.maxY
        let first = CGRect(x: window.frame.minX, y: top - 300, width: 510, height: 300)
        let latest = CGRect(x: window.frame.minX, y: top - 334, width: 510, height: 334)
        animator.resize(window: window, to: first, animated: true)
        animator.resize(window: window, to: latest, animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        #expect(window.frame == latest)
        #expect(window.nativeRequests.count > 2)
        #expect(window.nativeRequests.last?.frame == latest)
    }

    @Test @MainActor func popupSettlesAfterLayoutWithoutInterpolatingTheTopEdge() {
        _ = NSApplication.shared
        let window = makeWindow()
        defer { window.close() }
        let animator = PanelSizeAnimator()
        let top = window.frame.maxY
        let target = CGRect(x: window.frame.minX, y: top - 300, width: PanelMetrics.width, height: 300)
        animator.settleAfterLayout(window: window, to: target)
        #expect(window.frame.height == 464)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(window.frame == target)
        #expect(window.frame.maxY == top)
        #expect(window.manualFrameCalls == 1)
    }

    @MainActor private func makeWindow() -> NativeAnimationWindow {
        _ = NSApplication.shared
        let window = NativeAnimationWindow(contentRect: PanelTestSupport.windowFrame(size: CGSize(width: 510, height: 464)),
                                           styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: CGRect(origin: .zero, size: window.frame.size))
        window.nativeRequests = []
        window.manualFrameCalls = 0
        return window
    }

    @MainActor private final class NativeAnimationWindow: NSWindow {
        struct Request {
            let frame: CGRect
        }
        var nativeRequests: [Request] = []
        var manualFrameCalls = 0

        override func setFrame(_ frameRect: NSRect, display flag: Bool) {
            nativeRequests.append(Request(frame: frameRect))
            super.setFrame(frameRect, display: flag)
        }

        override func setFrame(_ frameRect: NSRect, display flag: Bool, animate: Bool) {
            manualFrameCalls += 1
            super.setFrame(frameRect, display: flag, animate: animate)
        }
    }
}
