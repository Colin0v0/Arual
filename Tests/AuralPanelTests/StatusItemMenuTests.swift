import AppKit
import Testing
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
            let menu = StatusItemMenu.make(openPanel: {}, openSettings: {}, showBattery: false,
                                           toggleBattery: {}, quit: {})
            #expect(menu.appearance == nil)
        }
    }

    @Test @MainActor func menuContainsBatteryToggleAndPrimaryActions() throws {
        var actions: [String] = []
        let menu = StatusItemMenu.make(openPanel: { actions.append("open") },
                                       openSettings: { actions.append("settings") },
                                       showBattery: true,
                                       toggleBattery: { actions.append("battery") },
                                       quit: { actions.append("quit") },
                                       version: "0.1.10")
        #expect(!menu.autoenablesItems)
        #expect(menu.items.map(\.title) == ["打开 Aural", "显示当前设备剩余电量", "版本 0.1.10",
                                           "设置…", "退出 Aural"])
        #expect(!menu.items.contains(where: { $0.isSeparatorItem }))
        #expect(menu.item(withTitle: "测试耳机") == nil)
        #expect(menu.item(withTitle: "显示当前设备剩余电量")?.state == .on)
        #expect(menu.item(withTitle: "版本 0.1.10")?.isEnabled == false)
        #expect(actions.isEmpty)
        for title in ["打开 Aural", "显示当前设备剩余电量", "设置…", "退出 Aural"] {
            let item = try #require(menu.item(withTitle: title))
            #expect(item.isEnabled)
            let action = try #require(item.action)
            #expect(NSApplication.shared.sendAction(action, to: item.target, from: item))
        }
        #expect(actions == ["open", "battery", "settings", "quit"])
    }

    @Test @MainActor func readyUpdateAddsRestartActionToStatusMenu() throws {
        var restarted = false
        let menu = StatusItemMenu.make(openPanel: {}, openSettings: {}, showBattery: false,
                                       toggleBattery: {}, quit: {},
                                       version: "0.1.10",
                                       restartVersion: "0.1.11",
                                       restartUpdate: { restarted = true })
        let item = try #require(menu.item(withTitle: "重启以更新到 0.1.11"))
        let action = try #require(item.action)
        #expect(NSApplication.shared.sendAction(action, to: item.target, from: item))
        #expect(restarted)
    }

    @Test func batteryTextOnlyUsesARealPercentageWhenEnabled() {
        #expect(StatusItemBatteryText.title(enabled: false, percent: 87).isEmpty)
        #expect(StatusItemBatteryText.title(enabled: true, percent: nil).isEmpty)
        #expect(StatusItemBatteryText.title(enabled: true, percent: -1).isEmpty)
        #expect(StatusItemBatteryText.title(enabled: true, percent: 101).isEmpty)
        #expect(StatusItemBatteryText.title(enabled: true, percent: 0) == "0%")
        #expect(StatusItemBatteryText.title(enabled: true, percent: 87) == "87%")
    }
}
