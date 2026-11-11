import AppKit
import SwiftUI

/// FineTune 风格浅灰平铺面板：分隔线区分设备与应用，不再使用白色卡片。
/// 所有尺寸均为 macOS 逻辑点，避免把参考截图的像素尺寸直接套进菜单栏弹窗。
enum PanelStyle {
    // 使用系统动态颜色，切换浅色/深色时无需重建主面板。
    private static let canvasLight = NSColor(red: 0.954, green: 0.958, blue: 0.963, alpha: 1)
    private static let canvasDark = NSColor(red: 0.118, green: 0.118, blue: 0.125, alpha: 1)
    private static let controlHoverLight = NSColor.white
    private static let controlHoverDark = NSColor(white: 1, alpha: 0.10)
    static let canvas = adaptive(light: canvasLight, dark: canvasDark)
    static let surface = adaptive(light: NSColor(red: 0.918, green: 0.928, blue: 0.940, alpha: 1),
                                  dark: NSColor(red: 0.165, green: 0.165, blue: 0.176, alpha: 1))
    static let accent = adaptive(light: NSColor(red: 0.05, green: 0.43, blue: 0.96, alpha: 1),
                                 dark: NSColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1))
    static let ink = adaptive(light: NSColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1),
                              dark: NSColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1))
    static let secondary = adaptive(light: NSColor(red: 0.45, green: 0.45, blue: 0.49, alpha: 1),
                                    dark: NSColor(red: 0.62, green: 0.62, blue: 0.66, alpha: 1))
    static let line = adaptive(light: NSColor(red: 0.88, green: 0.88, blue: 0.90, alpha: 1),
                               dark: NSColor(red: 0.26, green: 0.26, blue: 0.28, alpha: 1))
    // 内容不使用白色卡片，但可点击操作仍使用统一的白色悬停底色。
    static let controlHover = adaptive(light: controlHoverLight, dark: controlHoverDark)
    // 选中的页签是白色卡片；与设备图标的浅灰底、列表的平铺背景分开定义。
    static let tabSelection = adaptive(light: .white, dark: NSColor(red: 0.23, green: 0.23, blue: 0.24, alpha: 1))
    /// 分段控件使用中性浅灰轨道，选中项仍是白色胶囊，不借用系统蓝色的强调色。
    static let segmentTrack = adaptive(light: NSColor(red: 0.94, green: 0.94, blue: 0.95, alpha: 1),
                                       dark: NSColor(red: 0.20, green: 0.20, blue: 0.21, alpha: 1))
    static let iconSurface = adaptive(light: NSColor(white: 1, alpha: 0.72),
                                      dark: NSColor(red: 0.27, green: 0.27, blue: 0.29, alpha: 1))
    static let prominentFill = adaptive(light: NSColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1),
                                        dark: NSColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1))
    static let prominentInk = adaptive(light: .white, dark: NSColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1))
    /// 更新入口使用独立的紫色语义，避免和输出设备选中的系统蓝色混在一起。
    static let updateFill = adaptive(light: NSColor(red: 0.957, green: 0.949, blue: 1, alpha: 1),
                                     dark: NSColor(red: 0.19, green: 0.17, blue: 0.29, alpha: 1))
    static let updateBorder = adaptive(light: NSColor(red: 0.84, green: 0.81, blue: 0.97, alpha: 1),
                                       dark: NSColor(red: 0.39, green: 0.35, blue: 0.60, alpha: 1))
    static let updateInk = adaptive(light: NSColor(red: 0.33, green: 0.27, blue: 0.83, alpha: 1),
                                    dark: NSColor(red: 0.73, green: 0.68, blue: 1, alpha: 1))
    static let updateSolid = adaptive(light: NSColor(red: 0.34, green: 0.27, blue: 0.87, alpha: 1),
                                      dark: NSColor(red: 0.44, green: 0.36, blue: 1, alpha: 1))
    static let updateSolidInk = Color.white
    /// 悬停只做中性灰的层次变化，不用蓝色染色抢占设备选中态和功能色。
    /// 浅色用黑灰提亮，深色用白灰提亮，两者保持一致的视觉重量。
    static let rowHover = adaptive(light: NSColor(white: 0, alpha: 0.055),
                                   dark: NSColor(white: 1, alpha: 0.075))
    static let rowHoverBorder = adaptive(light: NSColor(white: 0, alpha: 0.08),
                                         dark: NSColor(white: 1, alpha: 0.10))
    /// 阴影只落在行的圆角底板下方，不包住文字，避免悬停时出现模糊字形。
    static let rowHoverGlow = adaptive(light: NSColor(white: 0, alpha: 0.06),
                                       dark: NSColor(white: 0, alpha: 0.18))
    static let iconHover = adaptive(light: NSColor(white: 0.92, alpha: 1),
                                    dark: NSColor(white: 1, alpha: 0.10))
    static let error = adaptive(light: NSColor(red: 0.69, green: 0.20, blue: 0.20, alpha: 1),
                                dark: NSColor(red: 1.0, green: 0.42, blue: 0.42, alpha: 1))
    static let radius: CGFloat = 11

    // 参考面板使用紧凑的系统字体；正文和标签统一为 12pt，避免中文中等字重显得过大。
    static let bodyFont = Font.system(size: 12, weight: .regular)
    static let titleFont = Font.system(size: 14, weight: .semibold)
    static let captionFont = Font.system(size: 11, weight: .regular)
    // 给三位数百分比预留完整宽度，保持读数单行，不挤压原生滑杆的操作高度。
    static let percentageWidth: CGFloat = 36

    // 动效只表达操作与状态变化；减少动态效果时直接切换，不启动装饰性动画。
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.88)
    }

    static let tabDuration: Double = 0.09
    // 原生窗口使用与 Magpie macOS 路径一致的短 ease-out；不再自写 60Hz 时钟。
    static let resizeDuration: Double = 0.16

    // 页签使用无回弹的短缓动，避免弹簧超调让选中块看起来“跳起来”。
    static func tabAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: tabDuration)
    }

    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .offset(y: 4))
    }

    static func canvasNSColor(for appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? canvasDark : canvasLight
    }

    /// AppKit 图层不会像 SwiftUI 一样自动解析动态颜色；
    /// 这里显式按当前外观返回悬停底色，避免深色模式拿到浅色主题的纯白。
    static func controlHoverNSColor(for appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? controlHoverDark
            : controlHoverLight
    }

    /// 同一套颜色随系统外观解析，避免每个视图各自判断 colorScheme 后产生色差。
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// 长文字操作只按内容扩展宽度；与正方形短操作共用高度、圆角和悬停底色。
struct PanelButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        PanelButtonBody(configuration: configuration, prominent: prominent,
                        reduceMotion: reduceMotion, isEnabled: isEnabled)
    }

    private struct PanelButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let prominent: Bool
        let reduceMotion: Bool
        let isEnabled: Bool
        // 沿用工程的 ObservableObject 状态模式，兼容当前 CLT 的 SwiftUI 工具链。
        @StateObject private var hover = HoverState()
        private final class HoverState: ObservableObject {
            @Published var active = false
        }

        var body: some View {
            configuration.label
                .foregroundStyle(prominent ? PanelStyle.prominentInk : PanelStyle.ink)
                .padding(.horizontal, PanelActionMetrics.horizontalPadding)
                .frame(minWidth: PanelActionMetrics.size).frame(height: PanelActionMetrics.size)
                .background {
                    RoundedRectangle(cornerRadius: PanelActionMetrics.cornerRadius)
                        .fill(prominent ? PanelStyle.prominentFill
                              : (hover.active || configuration.isPressed ? PanelStyle.controlHover : .clear))
                }
                .contentShape(RoundedRectangle(cornerRadius: PanelActionMetrics.cornerRadius))
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hover.active = $0 }
                .animation(PanelStyle.animation(reduceMotion: reduceMotion), value: configuration.isPressed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hover.active)
        }
    }
}

/// 设置页和布尔选项共用的分段控件；未选中文字保持浅灰，悬停才提升到正文色。
struct PanelSegmentedControl<Selection: Hashable>: View {
    let items: [Selection]
    @Binding var selection: Selection
    let title: (Selection) -> String
    @Namespace private var selectionNamespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                Button {
                    selection = item
                } label: {
                    Text(title(item))
                        .font(PanelStyle.bodyFont)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                        .frame(height: 27)
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(PanelSegmentButtonStyle(selected: selection == item,
                                                     namespace: selectionNamespace))
                .accessibilityAddTraits(selection == item ? .isSelected : [])
            }
        }
        .padding(2)
        .background(PanelStyle.segmentTrack, in: RoundedRectangle(cornerRadius: 9))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { moveSelection(by: -1) }
        .onKeyPress(.rightArrow) { moveSelection(by: 1) }
    }

    /// 分段控件只保留一个键盘焦点，方向键在选项之间移动，避免焦点停在已隐藏的胶囊里。
    private func moveSelection(by offset: Int) -> KeyPress.Result {
        guard let index = items.firstIndex(of: selection) else { return .ignored }
        let target = min(items.count - 1, max(0, index + offset))
        guard target != index else { return .handled }
        selection = items[target]
        return .handled
    }
}

/// 选中块使用独立白色胶囊；未选中项不再沿用系统分段控件的深色文字。
private struct PanelSegmentButtonStyle: ButtonStyle {
    let selected: Bool
    let namespace: Namespace.ID

    func makeBody(configuration: Configuration) -> some View {
        SegmentBody(configuration: configuration, selected: selected, namespace: namespace)
    }

    private struct SegmentBody: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        let namespace: Namespace.ID
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @StateObject private var hover = HoverState()

        private final class HoverState: ObservableObject {
            @Published var active = false
        }

        var body: some View {
            configuration.label
                // 悬停只改变文字对比度，不额外铺蓝色；选中项始终保持正文黑。
                .foregroundStyle(selected || (isEnabled && (hover.active || configuration.isPressed))
                                 ? PanelStyle.ink : PanelStyle.secondary)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(PanelStyle.tabSelection)
                            .shadow(color: PanelStyle.ink.opacity(0.08), radius: 1, y: 1)
                            .matchedGeometryEffect(id: "segment-selection", in: namespace)
                    }
                }
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hover.active = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hover.active)
        }
    }
}

/// 所有是/否设置统一使用关闭与开启两格，不使用系统蓝色开关。
struct PanelBooleanControl: View {
    @Binding var isOn: Bool
    @Environment(\.appLanguage) private var language

    var body: some View {
        PanelSegmentedControl(items: [false, true], selection: $isOn,
                              title: { value in
            L10n.text(value ? "开启" : "关闭", language: language)
        })
    }
}

/// 页签和白色选中卡片彼此独立：滑块始终只有一个实例，只沿固定轨道水平移动。
/// 不再在不同 Button 的背景里销毁、重建 matchedGeometry 节点，避免快速反向点击时跳位。
struct PanelTabs<Selection: Hashable>: View {
    let items: [Selection]
    let selection: Selection
    let title: (Selection) -> String
    var count: (Selection) -> Int? = { _ in nil }
    let select: (Selection) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { item in
                Button { select(item) } label: {
                    HStack(spacing: 5) {
                        Text(title(item))
                        if let value = count(item), value > 0 {
                            Text("\(value)").monospacedDigit()
                        }
                    }
                    .font(PanelStyle.bodyFont)
                    .frame(maxWidth: .infinity).frame(height: 27)
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(PanelTabButtonStyle(selected: selection == item))
                .accessibilityAddTraits(selection == item ? .isSelected : [])
            }
        }
        .background(alignment: .leading) {
            GeometryReader { geometry in
                if let index = items.firstIndex(of: selection) {
                    let width = (geometry.size.width - CGFloat(items.count - 1) * 4) / CGFloat(items.count)
                    RoundedRectangle(cornerRadius: 9)
                        .fill(PanelStyle.tabSelection)
                        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(PanelStyle.line, lineWidth: 1) }
                        .shadow(color: PanelStyle.ink.opacity(0.06), radius: 1, y: 1)
                        .frame(width: width, height: 27)
                        .offset(x: CGFloat(index) * (width + 4))
                        .animation(PanelStyle.tabAnimation(reduceMotion: reduceMotion), value: selection)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// 应用页签与耳机模式共用悬停规则；只改变文字，未选中的标签不出现选中块。
struct PanelTabButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        TabBody(configuration: configuration, selected: selected)
    }

    private struct TabBody: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @StateObject private var hover = HoverState()
        private final class HoverState: ObservableObject {
            @Published var active = false
        }

        var body: some View {
            configuration.label
                // 计数与标题继承同一前景色；禁用时不响应悬停，仍保留实际选中状态。
                .foregroundStyle(selected || (isEnabled && (hover.active || configuration.isPressed))
                                 ? PanelStyle.ink : PanelStyle.secondary)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hover.active = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hover.active)
        }
    }
}

/// 系统音量与应用增益使用同一种读数布局，100% 也不允许换行。
struct PanelPercentage: View {
    let value: Float

    var body: some View {
        Text(value, format: .percent.precision(.fractionLength(0)))
            .font(PanelStyle.bodyFont)
            .monospacedDigit()
            .foregroundStyle(PanelStyle.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: PanelStyle.percentageWidth, alignment: .trailing)
    }
}

struct PanelDivider: View {
    var body: some View { Rectangle().fill(PanelStyle.line.opacity(0.7)).frame(height: 1).accessibilityHidden(true) }
}

struct PanelError: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            // 不继承上层的纯图标样式，否则报错会只剩一个无法解释的红色感叹号。
            .labelStyle(.titleAndIcon)
            .foregroundStyle(PanelStyle.error)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// 列表行与设置行共用同一套悬停状态，避免每处自行决定底色、圆角和动画时长。
@MainActor
final class PanelRowHoverState: ObservableObject {
    @Published var active: Bool

    /// 默认从静止态开始；截图测试可显式传入悬停态，产品交互仍只由真实鼠标进入/离开驱动。
    init(active: Bool = false) {
        self.active = active
    }
}

/// 整行悬停使用中性灰底板、细描边和低位阴影。
/// 不使用位移或缩放，鼠标扫过时文字与滑杆保持原位，不会产生布局抖动。
private struct PanelRowHoverModifier: ViewModifier {
    let active: Bool
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(active ? PanelStyle.rowHover : Color.clear)
                    .shadow(color: active ? PanelStyle.rowHoverGlow : .clear, radius: 3, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(active ? PanelStyle.rowHoverBorder : Color.clear, lineWidth: 1)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: active)
    }
}

extension View {
    func panelRowHover(_ active: Bool, cornerRadius: CGFloat = 8) -> some View {
        modifier(PanelRowHoverModifier(active: active, cornerRadius: cornerRadius))
    }
}

