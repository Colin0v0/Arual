import AppKit
import AuralCore

/// 按下时就确定操作；按钮不接收 mouseUp，避免外部关闭监听与抬起动作把浮层重新打开。
enum StatusItemInteraction {
    enum Action: Equatable { case showPanel, hidePanel, showMenu }
    static let actionEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]

    static func action(eventType: NSEvent.EventType?, modifiers: NSEvent.ModifierFlags = [],
                       popupPresented: Bool) -> Action? {
        switch eventType {
        case .rightMouseDown:
            return .showMenu
        case .leftMouseDown:
            if modifiers.contains(.control) { return .showMenu }
            return popupPresented ? .hidePanel : .showPanel
        case nil:
            // 辅助功能的 performClick 没有鼠标事件，语义仍是普通的打开/收起。
            return popupPresented ? .hidePanel : .showPanel
        default:
            return nil
        }
    }

    /// 状态栏事件有时没有原 window；用同一屏幕坐标系命中，不能将按钮误当外部点击。
    static func hitsButton(event: NSEvent, buttonFrame: CGRect) -> Bool {
        let point: CGPoint
        if let window = event.window { point = window.convertPoint(toScreen: event.locationInWindow) }
        else { point = event.locationInWindow }
        return buttonFrame.contains(point)
    }
}

@MainActor
enum StatusItemMenu {
    static func make(openPanel: @escaping () -> Void, openSettings: @escaping () -> Void,
                     showBattery: Bool, toggleBattery: @escaping () -> Void,
                     quit: @escaping () -> Void,
                     version: String = AuralVersion.current,
                     restartVersion: String? = nil,
                     restartUpdate: @escaping () -> Void = {},
                     language: AppLanguage = .chinese) -> NSMenu {
        let menu = NSMenu()
        // 不覆盖 appearance：菜单材质、深浅与文字交给状态栏原生菜单路径决定。
        menu.autoenablesItems = false
        // 电量显示是可切换的菜单栏选项，具体数值仍只在图标右侧展示。
        menu.addItem(PanelActionMenuItem(title: L10n.text("打开 Aural", language: language), handler: openPanel))
        let batteryItem = PanelActionMenuItem(title: L10n.text("显示当前设备剩余电量", language: language),
                                              handler: toggleBattery)
        batteryItem.state = showBattery ? .on : .off
        menu.addItem(batteryItem)
        // 版本号是不可点击信息项，右键即可确认当前运行的构建。
        let versionItem = NSMenuItem(title: L10n.format("版本 %@", language: language, arguments: [version]),
                                     action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        if let restartVersion {
            menu.addItem(PanelActionMenuItem(
                title: L10n.format("重启以更新到 %@", language: language, arguments: [restartVersion]),
                handler: restartUpdate
            ))
        }
        menu.addItem(PanelActionMenuItem(title: L10n.text("设置…", language: language), handler: openSettings))
        // 保留应用原有退出委托，资源清理失败仍由主模型明确上报。
        menu.addItem(PanelActionMenuItem(title: L10n.text("退出 Aural", language: language), handler: quit))
        return menu
    }
}

/// 菜单栏只显示已经由真实设备回读的电量，不用占位值或推测电量。
enum StatusItemBatteryText {
    static func title(enabled: Bool, percent: Int?) -> String {
        guard enabled, let percent, (0...100).contains(percent) else { return "" }
        return "\(percent)%"
    }
}
