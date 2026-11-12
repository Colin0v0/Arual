import AppKit
import SwiftUI

/// 控件共用尺寸规范；支持仅改变前景色，避免入口按钮的悬停底板干扰视觉对齐。
enum PanelActionHoverStyle: Equatable {
    case background
    case foregroundOnly
}

struct PanelActionButton: NSViewRepresentable {
    enum Content: Equatable {
        case symbol(String)
        case text(String)
    }

    let content: Content
    let title: String
    let action: () -> Void
    let menu: (() -> NSMenu)?
    let tint: Color?
    let hoverStyle: PanelActionHoverStyle
    let isLoading: Bool
    /// 路由入口需要单击直接展开 NSMenu；其他按钮仍保持左键执行主操作。
    var showsMenuOnClick = false
    var alignsContentToTrailing = false
    @Environment(\.isEnabled) private var isEnabled

    init(systemName: String, title: String, tint: Color? = nil,
         hoverStyle: PanelActionHoverStyle = .background,
         action: @escaping () -> Void = {}, menu: (() -> NSMenu)? = nil) {
        content = .symbol(systemName)
        self.title = title
        self.action = action
        self.menu = menu
        self.tint = tint
        self.hoverStyle = hoverStyle
        isLoading = false
    }

    init(_ title: String, isLoading: Bool = false,
         hoverStyle: PanelActionHoverStyle = .background, action: @escaping () -> Void) {
        content = .text(title)
        self.title = title
        self.action = action
        menu = nil
        tint = nil
        self.hoverStyle = hoverStyle
        self.isLoading = isLoading
    }

    func makeNSView(context: Context) -> PanelActionControl {
        PanelActionControl(frame: NSRect(origin: .zero, size: contentSize))
    }

    func updateNSView(_ button: PanelActionControl, context: Context) {
        if button.hoverStyle != hoverStyle { button.hoverStyle = hoverStyle }
        (button.cell as? PanelActionCell)?.alignsContentToTrailing = alignsContentToTrailing
        button.setContent(content)
        let nextTint = tint.map { NSColor($0) }
        if button.idleTint != nextTint { button.idleTint = nextTint }
        button.isLoading = isLoading
        let nextEnabled = isEnabled && !isLoading
        if button.isEnabled != nextEnabled { button.isEnabled = nextEnabled }
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(isLoading ? "正在\(title)" : nil)
        button.activate = action
        button.makeMenu = menu
        button.showsMenuOnClick = showsMenuOnClick
    }

    // 图标锁定宽高；文字只扩展宽度，不接受系统字形边距引入的额外高度。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PanelActionControl, context: Context) -> CGSize? {
        contentSize
    }

    private var contentSize: CGSize {
        switch content {
        case .symbol: return PanelActionMetrics.square
        case .text(let text): return PanelActionMetrics.textSize(text)
        }
    }
}

/// 操作按钮的唯一规范：同高同圆角，图标等宽，文字宽度由真实字宽与左右留白决定。
enum PanelActionMetrics {
    static let size: CGFloat = 26
    static let square = CGSize(width: size, height: size)
    static let cornerRadius: CGFloat = 4
    static let spacing: CGFloat = 6
    static let horizontalPadding: CGFloat = 10
    static let font = NSFont.systemFont(ofSize: 12)

    static func textSize(_ text: String) -> CGSize {
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        return CGSize(width: max(size, width + horizontalPadding * 2), height: size)
    }
}

/// 右侧入口按可见内容对齐，不改变按钮外框和点击范围。
final class PanelActionCell: NSButtonCell {
    var alignsContentToTrailing = false

    override func imageRect(forBounds rect: NSRect) -> NSRect {
        var result = super.imageRect(forBounds: rect)
        if alignsContentToTrailing { result.origin.x = rect.maxX - result.width }
        return result
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var result = super.titleRect(forBounds: rect)
        if alignsContentToTrailing {
            result.size.width = ceil(attributedTitle.size().width)
            result.origin.x = rect.maxX - result.width
        }
        return result
    }
}

final class PanelActionControl: NSButton {
    var activate: () -> Void = {}
    var makeMenu: (() -> NSMenu)?
    var showsMenuOnClick = false
    private var renderedContent: PanelActionButton.Content?
    var hoverStyle: PanelActionHoverStyle = .background { didSet { updateAppearance() } }
    var idleTint: NSColor? { didSet { updateAppearance() } }
    private var hoverArea: NSTrackingArea?
    private var hovered = false
    private var pressed = false
    // 布局保留逻辑标题；加载时原生 cell 的实际标题必须为空，而不是设成透明色。
    private var contentTitle = ""
    private let loadingIndicator = NSProgressIndicator()
    var isLoading = false {
        didSet {
            guard oldValue != isLoading else { return }
            // 使用真实任务状态切换，不用固定延迟制造“刷新完成”的假反馈。
            loadingIndicator.isHidden = !isLoading
            if isLoading { loadingIndicator.startAnimation(nil) }
            else { loadingIndicator.stopAnimation(nil) }
            needsLayout = true
            updateAppearance()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = PanelActionCell(textCell: "")
        title = ""
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        setButtonType(.momentaryChange)
        // 关闭 NSButtonCell 自带的图标变暗，前景色和背景由统一状态负责。
        (cell as? NSButtonCell)?.highlightsBy = []
        wantsLayer = true
        layer?.cornerRadius = PanelActionMetrics.cornerRadius
        target = self
        action = #selector(performPanelAction)
        // 加载圈是按钮的子视图，始终在原按钮内部居中；不在相邻布局中插入新控件。
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isIndeterminate = true
        loadingIndicator.isDisplayedWhenStopped = false
        loadingIndicator.isHidden = true
        loadingIndicator.setAccessibilityElement(false)
        addSubview(loadingIndicator)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("面板按钮只通过代码创建")
    }

    override var intrinsicContentSize: NSSize {
        imagePosition == .noImage ? PanelActionMetrics.textSize(contentTitle) : PanelActionMetrics.square
    }

    // NSButton 默认按图标字形附加不同的对齐边距，会把 SwiftUI 的 26pt 变成 31～33pt。
    // 清零后，真实 bounds 与设计尺寸一致：图标 26×26，文字为内容宽度×26。
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }

    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    func setContent(_ content: PanelActionButton.Content) {
        // 页面切换会重建 SwiftUI 行，但原生按钮内容未变时不能重复创建 SF Symbol。
        guard renderedContent != content else { return }
        renderedContent = content
        switch content {
        case .symbol(let name):
            contentTitle = ""
            title = ""
            image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            imagePosition = .imageOnly
        case .text(let text):
            image = nil
            contentTitle = text
            imagePosition = .noImage
        }
        invalidateIntrinsicContentSize()
        updateAppearance()
    }

    override func layout() {
        super.layout()
        let diameter: CGFloat = 14
        loadingIndicator.frame = NSRect(x: (bounds.width - diameter) / 2,
                                        y: (bounds.height - diameter) / 2,
                                        width: diameter, height: diameter)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        updateHoverFromPointer()
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateAppearance()
    }

    override func highlight(_ flag: Bool) {
        pressed = flag
        updateAppearance()
    }

    /// 左键始终执行主操作；选项菜单只在右键时弹出，避免齿轮入口还要多一次点击。
    override func rightMouseDown(with event: NSEvent) {
        guard let makeMenu else {
            super.rightMouseDown(with: event)
            return
        }
        makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: -3), in: self)
        pressed = false
        updateHoverFromPointer()
    }

    /// 同时支持系统通过 context-menu 事件请求菜单，保证触控板和辅助功能路径一致。
    override func menu(for event: NSEvent) -> NSMenu? {
        makeMenu?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // 动态颜色必须在外观切换后重新写入 CALayer，否则悬停底色仍停留在旧主题。
        updateAppearance()
    }

    private func updateAppearance() {
        let highlighted = isEnabled && (hovered || pressed)
        let color: NSColor
        if highlighted { color = NSColor(PanelStyle.ink) }
        else if let idleTint { color = idleTint }
        else { color = NSColor(PanelStyle.secondary) }
        contentTintColor = color
        // 禁用状态的 NSButtonCell 会重绘灰色标题，不能靠透明色隐藏；加载时真正清空绘制文本。
        attributedTitle = NSAttributedString(string: isLoading ? "" : contentTitle, attributes: [
            .font: PanelActionMetrics.font, .foregroundColor: color
        ])
        needsDisplay = true
        // 仅前景模式在悬停和按下时都保持透明，不缩小原来的点击范围。
        let showBackground = (highlighted || isLoading) && hoverStyle == .background
        // CALayer 保存的是静态 CGColor，必须按当前 effectiveAppearance 解析；
        // 直接桥接 SwiftUI 动态 Color 会在深色模式下错误沿用浅色主题的白色。
        let hoverColor = PanelStyle.controlHoverNSColor(for: effectiveAppearance)
        layer?.backgroundColor = (showBackground ? hoverColor : NSColor.clear).cgColor
        alphaValue = isEnabled || isLoading ? 1 : 0.4
    }

    private func updateHoverFromPointer() {
        if let window {
            hovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        } else {
            hovered = false
        }
        updateAppearance()
    }

    @objc private func performPanelAction() {
        guard !isLoading else { return }
        if showsMenuOnClick, let menu = makeMenu?() {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -3), in: self)
            pressed = false
            updateHoverFromPointer()
            return
        }
        activate()
    }
}

/// 菜单项自己持有操作，生命周期跟随本次菜单，不依赖隐式 responder。
final class PanelActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: nil, keyEquivalent: "")
        target = self
        action = #selector(runHandler)
    }

    required init(coder: NSCoder) {
        fatalError("面板菜单项只通过代码创建")
    }

    @objc private func runHandler() { handler() }
}
