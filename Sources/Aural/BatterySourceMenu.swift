import AppKit
import SwiftUI
import AuralCore

/// 设置页的电量来源下拉：外观沿用 Aural 的白底细边框，展开菜单使用原生 NSMenu。
struct BatterySourceMenu: NSViewRepresentable {
    struct Item: Equatable {
        let title: String
        let source: MenuBarBatterySource
        let enabled: Bool
        let separatorBefore: Bool

        init(title: String, source: MenuBarBatterySource,
             enabled: Bool = true, separatorBefore: Bool = false) {
            self.title = title
            self.source = source
            self.enabled = enabled
            self.separatorBefore = separatorBefore
        }
    }

    let title: String
    let selected: MenuBarBatterySource
    let items: [Item]
    let onSelect: (MenuBarBatterySource) -> Void

    func makeNSView(context: Context) -> BatterySourceMenuControl {
        BatterySourceMenuControl()
    }

    func updateNSView(_ view: BatterySourceMenuControl, context: Context) {
        view.update(title: title, selected: selected, items: items, onSelect: onSelect)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BatterySourceMenuControl,
                      context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

/// 原生 NSMenu 负责菜单项与勾选；自绘按钮只负责外部 Aural 样式和动态宽度。
final class BatterySourceMenuControl: NSButton {
    static let height: CGFloat = 30
    static let horizontalPadding: CGFloat = 10
    static let titleToChevronSpacing: CGFloat = 7
    static let font = NSFont.systemFont(ofSize: 12)

    private var selectedTitle = ""
    private(set) var selectedSource = MenuBarBatterySource.off
    private var items: [BatterySourceMenu.Item] = []
    private var onSelect: (MenuBarBatterySource) -> Void = { _ in }

    init() {
        super.init(frame: NSRect(origin: .zero,
                                 size: NSSize(width: 0, height: Self.height)))
        cell = BatterySourceMenuCell(textCell: "")
        isBordered = false
        focusRingType = .none
        alignment = .left
        imagePosition = .imageTrailing
        imageScaling = .scaleProportionallyDown
        image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        contentTintColor = PanelStyle.secondaryNSColor
        target = self
        action = #selector(openMenu)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        // 触发器的宽度由完整标题决定，父级 HStack 不能把它压缩回固定宽度。
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("电量来源菜单只通过代码创建")
    }

    override var intrinsicContentSize: NSSize {
        let titleWidth = ceil((selectedTitle as NSString).size(withAttributes: [.font: Self.font]).width)
        let imageWidth = image?.size.width ?? 0
        let width = Self.horizontalPadding * 2 + titleWidth
            + Self.titleToChevronSpacing + imageWidth
        // 不设最小宽度：短标题按自身内容收缩，长标题再随内容增长。
        return NSSize(width: ceil(width), height: Self.height)
    }

    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    func update(title: String, selected: MenuBarBatterySource,
                items: [BatterySourceMenu.Item],
                onSelect: @escaping (MenuBarBatterySource) -> Void) {
        // 标题只用于绘制；勾选状态必须按真实 source 比较，不能依赖可能重名的菜单标题。
        let titleChanged = self.selectedTitle != title
        self.selectedTitle = title
        self.selectedSource = selected
        self.items = items
        self.onSelect = onSelect
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Self.font,
            .foregroundColor: PanelStyle.inkNSColor
        ])
        toolTip = title
        setAccessibilityLabel(title)
        if titleChanged {
            invalidateIntrinsicContentSize()
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    /// 同时支持鼠标点击与辅助功能的菜单请求路径。
    override func menu(for event: NSEvent) -> NSMenu? {
        makeMenu()
    }

    @objc private func openMenu() {
        makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: -3), in: self)
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item.separatorBefore {
                menu.addItem(.separator())
            }
            let menuItem = NSMenuItem(title: item.title,
                                      action: #selector(selectMenuItem(_:)),
                                      keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.source.storageValue
            menuItem.state = item.source == selectedSource ? .on : .off
            menuItem.isEnabled = item.enabled
            menu.addItem(menuItem)
        }
        return menu
    }

    @objc private func selectMenuItem(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let source = MenuBarBatterySource(storageValue: value) else { return }
        onSelect(source)
    }

    private func updateAppearance() {
        // CGColor 不随动态颜色自动切换，外观变化时必须重新解析 Aural 的现有控件色。
        layer?.backgroundColor = PanelStyle.tabSelectionNSColor.cgColor
        layer?.borderColor = PanelStyle.lineNSColor.cgColor
    }

}

/// 标题靠左、箭头贴右，避免 NSButton 默认把图标紧贴文字后留下不可控空白。
final class BatterySourceMenuCell: NSButtonCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        rect
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let imageWidth = image?.size.width ?? 0
        return NSRect(x: rect.minX + BatterySourceMenuControl.horizontalPadding,
                      y: rect.minY,
                      width: max(0, rect.width - BatterySourceMenuControl.horizontalPadding * 2
                                 - imageWidth - BatterySourceMenuControl.titleToChevronSpacing),
                      height: rect.height)
    }

    override func imageRect(forBounds rect: NSRect) -> NSRect {
        guard let image else { return .zero }
        return NSRect(x: rect.maxX - BatterySourceMenuControl.horizontalPadding - image.size.width,
                      y: rect.midY - image.size.height / 2,
                      width: image.size.width,
                      height: image.size.height)
    }
}
