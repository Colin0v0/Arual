import AppKit
import Testing
@testable import Aural

struct SettingsWindowFocusTests {
    @Test @MainActor func clickingBlankSpaceClearsFocusAndPreservesKeyboardNavigation() throws {
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 100),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = PanelActionControl(frame: NSRect(x: 10, y: 10, width: 26, height: 26))
        window.contentView?.addSubview(button)
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(button))
        #expect(window.firstResponder === button)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 140, y: 70),
                                                   modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        // 点击空白取消已有焦点，之后仍然可以通过键盘重新聚焦。
        window.sendEvent(event)
        #expect(window.firstResponder !== button)
        #expect(window.makeFirstResponder(button))
        #expect(window.firstResponder === button)
        window.close()
    }
}
