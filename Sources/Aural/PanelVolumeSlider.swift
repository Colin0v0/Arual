import SwiftUI

/// FineTune 风格的细轨音量条：不绘制白色大圆钮，悬停和键盘聚焦时显示小型蓝色定位点。
/// 拖动区域仍为 26pt 高，保留键盘和辅助功能调节，不把视觉轨道高度当作点击高度。
struct PanelVolumeSlider: View {
    @Binding var value: Double
    let label: String
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @StateObject private var hover = HoverState()
    private final class HoverState: ObservableObject {
        @Published var active = false
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 6)
            ZStack(alignment: .leading) {
                Capsule().fill(PanelStyle.line)
                Capsule().fill(PanelStyle.accent).frame(width: width * value)
                Circle().fill(PanelStyle.accent).frame(width: 6, height: 6)
                    .offset(x: width * value - 3)
                    .opacity(hover.active || focused ? 1 : 0)
            }
            .frame(width: width, height: 3)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard isEnabled else { return }
                focused = true
                value = PanelSliderMetrics.value(at: drag.location.x, width: geometry.size.width)
            })
        }
        .frame(height: PanelActionMetrics.size)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hover.active = $0 }
        .focusable(isEnabled)
        // 使用小圆点表示键盘焦点，关闭系统默认的整块蓝色矩形，不移除键盘调节能力。
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { adjust(by: -0.05) }
        .onKeyPress(.downArrow) { adjust(by: -0.05) }
        .onKeyPress(.rightArrow) { adjust(by: 0.05) }
        .onKeyPress(.upArrow) { adjust(by: 0.05) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((value * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: value = min(1, value + 0.05)
            case .decrement: value = max(0, value - 0.05)
            @unknown default: break
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hover.active)
    }

    private func adjust(by delta: Double) -> KeyPress.Result {
        guard isEnabled else { return .ignored }
        value = min(1, max(0, value + delta))
        return .handled
    }
}

enum PanelSliderMetrics {
    static func value(at x: CGFloat, width: CGFloat) -> Double {
        Double(min(1, max(0, (x - 3) / max(1, width - 6))))
    }
}
