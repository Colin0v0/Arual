import AppKit
import Testing
@testable import Aural

struct StatusPopupFocusTests {
    @Test @MainActor func openingPanelDoesNotKeepPreviousButtonFocus() {
        let panel = StatusPopupPanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 100),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let button = PanelActionControl(frame: NSRect(x: 10, y: 10, width: 26, height: 26))
        panel.contentView?.addSubview(button)
        panel.presentImmediately(frame: panel.frame)
        #expect(panel.firstResponder !== button)
        panel.orderOut(nil)
    }

    @Test @MainActor func mouseClickClearsKeyboardFocusWithoutDisablingTheButton() throws {
        let panel = StatusPopupPanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 100),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let button = PanelActionControl(frame: NSRect(x: 10, y: 10, width: 26, height: 26))
        panel.contentView?.addSubview(button)
        panel.presentImmediately(frame: panel.frame)
        #expect(panel.makeFirstResponder(button))
        #expect(panel.firstResponder === button)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 140, y: 70),
                                                   modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        // 点击空白处后焦点移除，原控件仍可通过键盘再次取得焦点。
        panel.sendEvent(event)
        #expect(panel.firstResponder !== button)
        #expect(panel.makeFirstResponder(button))
        #expect(panel.firstResponder === button)
        panel.orderOut(nil)
    }
}
