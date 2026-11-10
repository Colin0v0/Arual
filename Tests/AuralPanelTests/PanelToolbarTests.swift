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

    @Test @MainActor func controlsUseWhiteHoverRatherThanTheGrayPageSurface() throws {
        let color = try #require(NSColor(PanelStyle.controlHover).usingColorSpace(.deviceRGB))
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

}
