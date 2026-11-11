import AppKit
import SwiftUI
import Testing
@testable import Aural

struct PanelToolbarTests {
    @Test @MainActor func toolbarUsesCompactSquareTargets() {
        let button = PanelActionControl(frame: .zero)
        #expect(button.intrinsicContentSize == NSSize(width: 26, height: 26))
        #expect(button.layer?.cornerRadius == 4)
        #expect(!button.isBordered)
        #expect((button.cell as? NSButtonCell)?.highlightsBy == [])
    }

    @Test @MainActor func lightControlsUseWhiteHoverRatherThanTheGrayPageSurface() throws {
        // 其他设置测试会切换全局外观；浅色断言必须显式指定 Aqua，不能依赖运行顺序。
        let appearance = try #require(NSAppearance(named: .aqua))
        let color = try #require(PanelStyle.controlHoverNSColor(for: appearance).usingColorSpace(.deviceRGB))
        #expect(color.redComponent == 1)
        #expect(color.greenComponent == 1)
        #expect(color.blueComponent == 1)
        #expect(color.alphaComponent == 1)
    }

    // 入口按钮没有单独的 Menu 外观分支，任一图标都经过相同的高亮和恢复路径。
    @Test(arguments: ["arrow.clockwise", "arrow.up.right.square", "gearshape"])
    @MainActor func toolbarHighlightIsIdenticalAndReversible(symbol: String) throws {
        let button = PanelActionControl(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        button.setContent(.symbol(symbol))
        #expect(button.image != nil)
        button.highlight(true)
        #expect(button.contentTintColor == NSColor(PanelStyle.ink))
        #expect(button.layer?.backgroundColor == NSColor(PanelStyle.controlHover).cgColor)
        button.highlight(false)
        #expect(button.contentTintColor == NSColor(PanelStyle.secondary))
        #expect(button.layer?.backgroundColor == NSColor.clear.cgColor)
    }

    @Test(arguments: ["speaker.wave.2", "speaker.slash", "speaker.slash.fill"])
    @MainActor func speakerHoverChangesColorWithoutBackground(symbol: String) {
        let button = PanelActionControl(frame: NSRect(origin: .zero, size: PanelActionMetrics.square))
        button.hoverStyle = .foregroundOnly
        button.setContent(.symbol(symbol))
        #expect(button.contentTintColor == NSColor(PanelStyle.secondary))
        button.highlight(true)
        #expect(button.contentTintColor == NSColor(PanelStyle.ink))
        #expect(button.layer?.backgroundColor == NSColor.clear.cgColor)
        button.highlight(false)
        #expect(button.contentTintColor == NSColor(PanelStyle.secondary))
        #expect(button.layer?.backgroundColor == NSColor.clear.cgColor)
        #expect(button.intrinsicContentSize == PanelActionMetrics.square)
    }

    @Test @MainActor func disabledSpeakerDoesNotHighlightOrLoseMuteColor() {
        let button = PanelActionControl(frame: NSRect(origin: .zero, size: PanelActionMetrics.square))
        button.hoverStyle = .foregroundOnly
        button.idleTint = .systemRed
        button.setContent(.symbol("speaker.slash"))
        button.isEnabled = false
        button.highlight(true)
        #expect(button.contentTintColor == NSColor.systemRed)
        #expect(button.layer?.backgroundColor == NSColor.clear.cgColor)
        #expect(button.alphaValue == 0.4)
    }

    @Test @MainActor func settingsAndQuitOnlyChangeForegroundWithoutMoving() {
        // 设置和退出入口保持原有点击范围；悬停及按下都只改前景，不出现白色底板。
        let settings = PanelActionButton(systemName: "gearshape", title: "设置", hoverStyle: .foregroundOnly)
        let quit = PanelActionButton("退出", hoverStyle: .foregroundOnly) {}
        #expect(settings.hoverStyle == .foregroundOnly)
        #expect(quit.hoverStyle == .foregroundOnly)
        for content in [settings.content, quit.content] {
            let button = PanelActionControl(frame: NSRect(origin: .zero, size: PanelActionMetrics.square))
            button.hoverStyle = .foregroundOnly
            button.setContent(content)
            let size = button.intrinsicContentSize
            button.mouseEntered(with: NSEvent())
            #expect(button.contentTintColor == NSColor(PanelStyle.ink))
            #expect(button.layer?.backgroundColor == NSColor.clear.cgColor)
            button.highlight(true)
            #expect(button.layer?.backgroundColor == NSColor.clear.cgColor)
            button.highlight(false)
            button.mouseExited(with: NSEvent())
            #expect(button.contentTintColor == NSColor(PanelStyle.secondary))
            #expect(button.intrinsicContentSize == size)
        }
    }

    @Test @MainActor func trailingActionsAlignVisibleEdgesWithoutChangingTargets() throws {
        for content: PanelActionButton.Content in [.symbol("gearshape"), .text("Quit"), .text("退出")] {
            let button = PanelActionControl(frame: NSRect(x: 0, y: 0, width: 60, height: 26))
            let cell = try #require(button.cell as? PanelActionCell)
            cell.alignsContentToTrailing = true
            button.setContent(content)
            let size = button.intrinsicContentSize
            let visibleRect: NSRect
            switch content {
            case .symbol: visibleRect = cell.imageRect(forBounds: button.bounds)
            case .text: visibleRect = cell.titleRect(forBounds: button.bounds)
            }
            #expect(visibleRect.maxX == button.bounds.maxX)
            button.highlight(true)
            #expect(button.intrinsicContentSize == size)
        }
    }

}
