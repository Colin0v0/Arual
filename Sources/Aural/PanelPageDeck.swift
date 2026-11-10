import SwiftUI

/// 页面常驻同一个顶部对齐的内容区域，只用透明度切换，保留各页滚动位置。
/// 外框由页面布局状态控制，不拿 ZStack 的最大自然高度替代当前页的目标高度。
struct PanelPageDeck<Selection: Hashable, Page: View>: View {
    let items: [Selection]
    let selection: Selection
    @ViewBuilder let page: (Selection) -> Page

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(items, id: \.self) { item in
                page(item)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    // 内容立即切换，只让页签指示器做短滑动；交叉淡入会让两页短暂叠在一起。
                    .opacity(selection == item ? 1 : 0)
                    .allowsHitTesting(selection == item)
                    // 常驻隐藏页也必须禁用键盘操作，避免 Tab 聚焦到不可见的麦克风或音量条。
                    .disabled(selection != item)
                    .accessibilityHidden(selection != item)
            }
        }
    }
}

/// 每页保留独立的滚动容器，外部共用一个稳定视口。
/// 从长应用列表切到耳机页时，不会继承应用页的滚动偏移而看到一块空白。
struct PanelPageViewport<Selection: Hashable, Page: View>: View {
    let items: [Selection]
    let selection: Selection
    let height: CGFloat
    let pageHeightsChanged: ([Selection: CGFloat]) -> Void
    @ViewBuilder let page: (Selection) -> Page

    var body: some View {
        PanelPageDeck(items: items, selection: selection) { item in
            ScrollView {
                page(item)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(PanelHiddenScrollbars().allowsHitTesting(false))
                    .background {
                        GeometryReader { geometry in
                            // 测量分别按页保存，隐藏页只能更新自己的记录，不能直接改变外框。
                            Color.clear.preference(key: PanelContentHeights<Selection>.self,
                                                   value: [item: ceil(geometry.size.height)])
                        }
                    }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(height: height)
        // 只报告各页独立的测量值；是否调整外框，由布局状态区分主动切页与后台更新。
        .onPreferenceChange(PanelContentHeights<Selection>.self, perform: pageHeightsChanged)
    }
}

private struct PanelContentHeights<Selection: Hashable>: PreferenceKey {
    static var defaultValue: [Selection: CGFloat] { [:] }
    static func reduce(value: inout [Selection: CGFloat], nextValue: () -> [Selection: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
