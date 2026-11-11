import AppKit
import QuartzCore

/// 只向 AppKit 提交目标外框，由系统显示时钟驱动窗口动画。
/// 不再用 NSAnimation 每帧 setFrame；否则窗口移动与 SwiftUI 宿主重排可能错开一帧。
@MainActor
final class PanelSizeAnimator {
    private weak var window: NSWindow?
    private var pendingTarget: CGRect?
    private var generation: UInt64 = 0

    /// 等本轮 SwiftUI 布局结束后直接落到目标外框。
    /// 顶边不进入 AppKit 的逐帧插值，避免外接屏像素取整时整框上下抖。
    func settleAfterLayout(window: NSWindow, to target: CGRect) {
        self.window = window
        generation &+= 1
        let requestGeneration = generation
        pendingTarget = target
        RunLoop.main.perform(inModes: [.common]) { [weak self, weak window] in
            MainActor.assumeIsolated {
                guard let self, let window, self.generation == requestGeneration,
                      let target = self.pendingTarget else { return }
                self.pendingTarget = nil
                window.contentView?.layoutSubtreeIfNeeded()
                self.apply(target: target, to: window, animated: false)
            }
        }
    }

    func resize(window: NSWindow, to target: CGRect, animated: Bool) {
        self.window = window
        generation &+= 1
        let requestGeneration = generation

        guard animated else {
            pendingTarget = nil
            apply(target: target, to: window, animated: false)
            return
        }

        // Magpie 的 macOS 路径在页面完成本轮布局后，把 glide 投递到下一轮主线程。
        // 若在 SwiftUI 更新事务内同步启动 AppKit 动画，窗口和宿主会抢同一帧提交。
        pendingTarget = target
        RunLoop.main.perform(inModes: [.common]) { [weak self, weak window] in
            MainActor.assumeIsolated {
                guard let self, let window, self.generation == requestGeneration,
                      let target = self.pendingTarget else { return }
                self.pendingTarget = nil
                window.contentView?.layoutSubtreeIfNeeded()
                self.apply(target: target, to: window, animated: true)
            }
        }
    }

    private func apply(target: CGRect, to window: NSWindow, animated: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            if animated {
                // 即使目标等于当前外框，也必须提交给同一个原生 animator。
                // 旧动画可能尚未推进首帧；此时改走同步 setFrame 不会撤销旧目标，
                // 快速反向切页就会被稍后到达的旧动画覆盖。
                // 与 Magpie 的 macOS 路径一样，只提交一次目标，不自行调度中间帧。
                context.duration = PanelStyle.resizeDuration
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                context.allowsImplicitAnimation = true
                window.animator().setFrame(target, display: true)
            } else {
                // 首次布局、减少动态效果直接同步到位，不把零时长更新排到下一帧。
                context.duration = 0
                context.allowsImplicitAnimation = false
                window.setFrame(target, display: true, animate: false)
            }
        }
    }

    func cancel() {
        generation &+= 1
        pendingTarget = nil
        guard let window else { return }
        let currentFrame = window.frame
        NSAnimationContext.runAnimationGroup { context in
            // 隐藏时用同一个原生属性终止旧目标；没有手动逐帧或其他后备动画。
            context.duration = 0
            context.allowsImplicitAnimation = false
            window.animator().setFrame(currentFrame, display: false)
        }
        self.window = nil
    }
}
