import AppKit
import SwiftUI
import Testing
@testable import Aural

struct PanelInteractionLayoutTests {
    /// 必须检查 SwiftUI 宿主里的真实 bounds；只测 intrinsicContentSize 会漏掉原生按钮的对齐边距。
    @Test @MainActor func hostedActionsShareHeightAndCornersButTextKeepsItsWidth() throws {
        let host = NSHostingView(rootView: fixture)
        host.frame.size = NSSize(width: PanelMetrics.width, height: 124)
        host.layoutSubtreeIfNeeded()
        let buttons = controls(in: host)
        #expect(buttons.count == 6)
        for button in buttons {
            let expected = button.imagePosition == .noImage
                ? PanelActionMetrics.textSize(button.title) : PanelActionMetrics.square
            #expect(button.bounds.size == expected)
            #expect(button.bounds.height == PanelActionMetrics.size)
            #expect(button.alignmentRectInsets.top == 0)
            #expect(button.alignmentRectInsets.bottom == 0)
            #expect(button.layer?.cornerRadius == PanelActionMetrics.cornerRadius)
            button.highlight(true)
            // 原生图层按按钮当前外观解析悬停色，测试也使用同一入口，避免只验证动态 Color 的桥接值。
            let background = button.hoverStyle == .background
                ? PanelStyle.controlHoverNSColor(for: button.effectiveAppearance)
                : NSColor.clear
            #expect(button.layer?.backgroundColor == background.cgColor)
            button.highlight(false)
        }
        let exit = try #require(buttons.first { $0.title == "退出" })
        #expect(exit.bounds.size == CGSize(width: 44, height: 26))
        #expect(PanelActionMetrics.horizontalPadding == 10)
        // 同一行内验证实际间隔，而不是只验证常量。
        let headerFrames = buttons.prefix(3).map { $0.convert($0.bounds, to: host) }.sorted { $0.minX < $1.minX }
        #expect(headerFrames[1].minX - headerFrames[0].maxX == PanelActionMetrics.spacing)
        #expect(headerFrames[2].minX - headerFrames[1].maxX == PanelActionMetrics.spacing)

        // 导出真正放进 SwiftUI 布局后的高亮对比，不再用手工摆放的 NSButton 代替页面验收。
        for button in buttons { button.highlight(true) }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/aural-panel-actions-preview.png"))
    }

    @Test @MainActor func disabledShortActionCannotHighlight() {
        let button = PanelActionControl(frame: NSRect(origin: .zero, size: PanelActionMetrics.square))
        button.setContent(.text("刷新"))
        button.isEnabled = false
        button.highlight(true)
        #expect(button.layer?.backgroundColor == NSColor.clear.cgColor)
        #expect(button.alphaValue == 0.4)
    }

    /// 带右键菜单的齿轮也必须左键直达设置，不能先弹一层工具菜单。
    @Test @MainActor func primaryClickRunsActionEvenWhenContextMenuExists() {
        let button = PanelActionControl(frame: NSRect(origin: .zero, size: PanelActionMetrics.square))
        button.setContent(.symbol("gearshape"))
        var actions = 0
        button.activate = { actions += 1 }
        button.makeMenu = { NSMenu() }

        _ = button.sendAction(button.action, to: button.target)

        #expect(actions == 1)
    }

    /// 深色模式的悬停应是低透明度提亮，不能退化为浅色主题的纯白背景。
    @Test @MainActor func darkHoverUsesSubtleLiftInsteadOfWhite() throws {
        let button = PanelActionControl(frame: NSRect(origin: .zero, size: PanelActionMetrics.square))
        button.setContent(.symbol("gearshape"))
        button.appearance = NSAppearance(named: .darkAqua)
        button.highlight(true)

        let color = try #require(button.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
        let resolved = color.usingColorSpace(.deviceRGB) ?? color
        #expect(resolved.redComponent > 0.9)
        #expect(resolved.alphaComponent < 0.2)
        #expect(resolved.alphaComponent > 0.05)

        // 同时导出真实深色背景下的悬停预览，便于肉眼检查细微提亮是否仍像白色按钮。
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 84, height: 84))
        host.wantsLayer = true
        host.layer?.backgroundColor = PanelStyle.canvasNSColor(for: button.effectiveAppearance).cgColor
        button.frame.origin = NSPoint(x: 29, y: 29)
        host.addSubview(button)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/aural-panel-actions-dark-preview.png"))
    }

    @MainActor private var fixture: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Aural").font(PanelStyle.titleFont)
                Spacer()
                HStack(spacing: PanelActionMetrics.spacing) {
                    PanelActionButton(systemName: "arrow.clockwise", title: "刷新")
                    PanelActionButton(systemName: "arrow.up.right.square", title: "打开")
                    PanelActionButton(systemName: "gearshape", title: "更多", menu: { NSMenu() })
                }
            }.padding(.horizontal, 12).frame(height: 44)
            PanelDivider()
            HStack {
                Text("应用行操作")
                Spacer()
                PanelActionButton(systemName: "speaker.wave.2", title: "静音", hoverStyle: .foregroundOnly)
                PanelActionButton(systemName: "speaker.slash", title: "静音操作", hoverStyle: .foregroundOnly)
            }.padding(.horizontal, 12).frame(height: 44)
            PanelDivider()
            HStack {
                Text("音频控制")
                Spacer()
                PanelActionButton("退出", action: {})
            }.padding(.horizontal, 12).frame(height: 34)
        }
        .font(PanelStyle.bodyFont).frame(width: PanelMetrics.width)
        .background(PanelStyle.canvas).preferredColorScheme(.light)
    }

    @MainActor private func controls(in view: NSView) -> [PanelActionControl] {
        if let button = view as? PanelActionControl { return [button] }
        return view.subviews.flatMap { controls(in: $0) }
    }
}
