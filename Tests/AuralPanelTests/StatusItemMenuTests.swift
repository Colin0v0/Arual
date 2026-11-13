import AppKit
import Testing
import AuralCore
@testable import Aural

struct StatusItemMenuTests {
    @Test func leftMouseDownTogglesAndMouseUpDoesNotReopen() {
        #expect(StatusItemInteraction.action(eventType: .leftMouseDown, popupPresented: false) == .showPanel)
        #expect(StatusItemInteraction.action(eventType: .leftMouseDown, popupPresented: true) == .hidePanel)
        #expect(StatusItemInteraction.action(eventType: .leftMouseUp, popupPresented: false) == nil)
        #expect(StatusItemInteraction.actionEvents == [.leftMouseDown, .rightMouseDown])
    }

    @Test(arguments: [false, true])
    func rightClickAndControlClickAlwaysOpenMenu(presented: Bool) {
        #expect(StatusItemInteraction.action(eventType: .rightMouseDown, popupPresented: presented) == .showMenu)
        #expect(StatusItemInteraction.action(eventType: .leftMouseDown, modifiers: [.control],
                                            popupPresented: presented) == .showMenu)
        #expect(StatusItemInteraction.action(eventType: .rightMouseUp, popupPresented: presented) == nil)
    }

    @Test func accessibilityClickStillToggles() {
        #expect(StatusItemInteraction.action(eventType: nil, popupPresented: false) == .showPanel)
        #expect(StatusItemInteraction.action(eventType: nil, popupPresented: true) == .hidePanel)
    }

    @Test @MainActor func statusItemHitTestingDoesNotRequireAnEventWindow() throws {
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: -700, y: 889),
                                                  modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(StatusItemInteraction.hitsButton(event: event, buttonFrame: CGRect(x: -710, y: 876, width: 24, height: 24)))
        #expect(!StatusItemInteraction.hitsButton(event: event, buttonFrame: CGRect(x: 710, y: 876, width: 24, height: 24)))
    }

    @Test @MainActor func eventWithWindowUsesScreenCoordinates() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 250, y: 300, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 10, y: 12),
                                                  modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(StatusItemInteraction.hitsButton(event: event, buttonFrame: CGRect(x: 250, y: 300, width: 24, height: 24)))
        #expect(!StatusItemInteraction.hitsButton(event: event, buttonFrame: CGRect(x: 0, y: 0, width: 24, height: 24)))
    }

    @Test @MainActor func menuLeavesAppearanceToAppKit() {
        let application = NSApplication.shared
        let previousAppearance = application.appearance
        defer { application.appearance = previousAppearance }
        // 不论当前外观如何，都不在菜单上写入覆盖值；原生状态栏负责选择实际外观。
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            application.appearance = NSAppearance(named: name)
            let menu = StatusItemMenu.make(openPanel: {}, openSettings: {}, quit: {})
            #expect(menu.appearance == nil)
        }
    }

    @Test @MainActor func menuContainsOnlyThreePrimaryActionsAndQuitSeparator() throws {
        var actions: [String] = []
        let menu = StatusItemMenu.make(openPanel: { actions.append("open") },
                                       openSettings: { actions.append("settings") },
                                       quit: { actions.append("quit") })
        #expect(!menu.autoenablesItems)
        #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["打开 Aural", "设置…", "退出 Aural"])
        #expect(menu.items.count == 4)
        #expect(menu.items[2].isSeparatorItem)
        #expect(actions.isEmpty)
        for item in menu.items where !item.isSeparatorItem {
            #expect(item.isEnabled)
            let action = try #require(item.action)
            #expect(NSApplication.shared.sendAction(action, to: item.target, from: item))
        }
        #expect(actions == ["open", "settings", "quit"])
    }

    @Test @MainActor func englishMenuUsesTheSameMinimalStructure() {
        let menu = StatusItemMenu.make(openPanel: {}, openSettings: {}, quit: {}, language: .english)
        #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Open Aural", "Settings…", "Quit Aural"])
        #expect(menu.items.count == 4)
        #expect(menu.items[2].isSeparatorItem)
    }

    @Test func batteryTextUsesOnlyRealProtocolValues() {
        #expect(StatusItemBatteryText.title(reading: nil).isEmpty)
        #expect(StatusItemBatteryText.title(reading: HeadphoneBatteryReading(single: -1)).isEmpty)
        #expect(StatusItemBatteryText.title(reading: HeadphoneBatteryReading(single: 101)).isEmpty)
        #expect(StatusItemBatteryText.title(reading: HeadphoneBatteryReading(single: 0)) == "0%")
        #expect(StatusItemBatteryText.title(reading: HeadphoneBatteryReading(single: 87)) == "87%")
    }

    @Test func dualEarbudBatteryStaysCompactAndCaseDoesNotUseNumericTitle() {
        #expect(StatusItemBatteryText.title(reading: HeadphoneBatteryReading(left: 82, right: 82)) == "82%")
        #expect(StatusItemBatteryText.title(reading: HeadphoneBatteryReading(left: 82, right: 79))
                == "L82 / R79")
        #expect(StatusItemBatteryText.title(reading: HeadphoneBatteryReading(left: 82)) == "L82")
        #expect(StatusItemBatteryText.title(reading: HeadphoneBatteryReading(right: 79)) == "R79")
        #expect(StatusItemBatteryText.title(reading: HeadphoneBatteryReading(caseLevel: 65)).isEmpty)
    }

    @Test func fullBatteryDetailLocalizesEveryAvailablePart() {
        let reading = HeadphoneBatteryReading(left: 82, right: 79, caseLevel: 65)
        #expect(HeadphoneBatteryText.detail(reading, language: .chinese) == "左 82% · 右 79% · 盒 65%")
        #expect(HeadphoneBatteryText.detail(reading, language: .english) == "L 82% · R 79% · Case 65%")
        #expect(StatusItemBatteryText.toolTip(reading: reading, deviceName: "AirPods",
                                             language: .english)
                == "Aural · AirPods · L 82% · R 79% · Case 65%")
    }
}
