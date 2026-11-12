import AppKit
import Combine
import SwiftUI
import AuralCore

/// 菜单栏浮层完全由自己持有：打开时确定一次锚点，之后只沿该锚点改变高度。
@MainActor
final class StatusPanelController: NSObject {
    private let popup: StatusPopupPanel
    private let statusItem: NSStatusItem
    private let model: AppModel
    private var settingsWindow: SettingsWindow?
    private var audioCaptureAlert: AudioCaptureAccessAlertController?
    private let popupLayout = PanelPresentationLayout()
    private let popupSizeAnimator = PanelSizeAnimator()
    private var popupTopLeft = CGPoint.zero
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var settingsLanguageCancellable: AnyCancellable?
    private var statusBatteryCancellables: Set<AnyCancellable> = []
    private var presentationGeneration: UInt64 = 0
    private var popupPresented = false

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let initialSize = PanelMetrics.size(contentHeight: 0)
        popup = StatusPopupPanel(contentRect: NSRect(origin: .zero, size: initialSize),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        popup.delegate = self
        popup.backgroundColor = .clear
        popup.isOpaque = false
        popup.hasShadow = true
        popup.isMovable = false
        popup.isMovableByWindowBackground = false
        popup.isReleasedWhenClosed = false
        popup.hidesOnDeactivate = false
        // 主面板位于普通窗口之上、系统菜单之下，允许右键菜单覆盖它而不互相抢层级。
        popup.level = .statusBar
        popup.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        popup.animationBehavior = .none
        popup.dismiss = { [weak self] in self?.hidePopup() }
        popupLayout.selectPage(AudioPanelPage.output)
        let layout = popupLayout
        let host = NSHostingController(rootView: StatusPopupSurface { [weak self] in
            AudioPanel(model: model, layout: layout, openSettings: { [weak self] in
                self?.showSettings()
            }, panelSizeChanged: { [weak self] size in
                self?.updatePopupSize(size)
            }, surface: .popover)
        })
        host.sizingOptions = []
        host.view.setFrameSize(initialSize)
        popup.contentViewController = host
        popup.installNativeBackdrop()
        if let button = statusItem.button {
            button.image = AuralStatusIcon.make()
            button.image?.accessibilityDescription = "Aural 音频控制"
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            button.target = self
            button.action = #selector(handleStatusItemAction)
            button.sendAction(on: StatusItemInteraction.actionEvents)
            button.toolTip = "Aural · 左键打开/收起，右键更多操作"
        }
        updateStatusItemBattery()
        statusBatteryCancellables.insert(AppSettings.shared.$showCurrentDeviceBattery
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStatusItemBattery() }
            })
        statusBatteryCancellables.insert(model.headphones.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStatusItemBattery() }
            })
        // 语言切换只重绘设置窗口标题，不重建已经打开的窗口内容。
        settingsLanguageCancellable = AppSettings.shared.$language
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateSettingsWindowTitle() }
            }
        audioCaptureAlert = AudioCaptureAccessAlertController(
            access: model.$audioCaptureAccess.eraseToAnyPublisher(),
            currentAccess: { model.audioCaptureAccess },
            language: { AppSettings.shared.resolvedLanguage },
            beforePresenting: { [weak self] in self?.hidePopup() },
            openSettings: model.openAudioCaptureSettings,
            requestAccess: model.requestAudioCaptureAccess,
            presentAlert: { alert in
                NSApp.activate(ignoringOtherApps: true)
                return alert.runModal()
            })
    }

    /// 齿轮和右键菜单都进入同一个真实设置窗口，不再复制主面板的设备控制内容。
    private func showSettings() {
        hidePopup()
        if settingsWindow == nil {
            let size = SettingsMetrics.size
            let window = SettingsWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.delegate = self
            window.title = settingsWindowTitle
            window.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: SettingsView(model: model, settings: AppSettings.shared))
            host.sizingOptions = []
            host.view.setFrameSize(size)
            window.contentViewController = host
            window.setContentSize(size)
            window.center()
            settingsWindow = window
        }
        updateSettingsWindowTitle()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 激活后清除系统自动选中的首个控件，仍允许用户主动使用 Tab 导航。
        settingsWindow?.makeFirstResponder(nil)
    }

    private func updatePopupSize(_ size: CGSize) {
        guard size == popupLayout.size else { return }
        // 一次计算目标外框并固定打开时的顶边；高度直接落位，顶边不参与窗口动画。
        let target = StatusPopupMetrics.frame(topLeft: popupTopLeft, size: size)
        popupSizeAnimator.settleAfterLayout(window: popup, to: target)
    }

    private func showPopup() {
        // 菜单里的“打开”是幂等操作，不会因浮层已经显示而反向收起。
        guard !popupPresented else { return }
        guard let button = statusItem.button, let buttonWindow = button.window, let screen = buttonWindow.screen else {
            assertionFailure("状态栏按钮尚无可用的屏幕锚点")
            return
        }
        let statusFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        popupLayout.setAvailableHeight(StatusPopupMetrics.availableHeight(statusItem: statusFrame,
                                                                          screen: screen.visibleFrame))
        popup.contentView?.layoutSubtreeIfNeeded()
        popupLayout.beginPresentation()
        let frame = StatusPopupMetrics.openingFrame(statusItem: statusFrame, screen: screen.visibleFrame,
                                                   contentSize: popupLayout.size)
        popupTopLeft = CGPoint(x: frame.minX, y: frame.maxY)
        popupSizeAnimator.cancel()
        // 设置页切换主题时主面板通常已收起；重新展示前再写入一次原生底色。
        popup.installNativeBackdrop()
        popup.presentImmediately(frame: frame)
        popupPresented = true
        button.highlight(true)
        presentationGeneration &+= 1
        installDismissMonitors(generation: presentationGeneration)
        model.setMeteringVisible(true, for: .popover)
        // 面板重新出现时补一次完整状态；隐藏期间只监听路由，避免后台反复扫描进程。
        Task { @MainActor [weak self] in self?.model.refresh() }
    }

    private func hidePopup() {
        guard popupPresented else { return }
        popupPresented = false
        presentationGeneration &+= 1
        popupSizeAnimator.cancel()
        removeDismissMonitors()
        popup.orderOut(nil)
        statusItem.button?.highlight(false)
        model.setMeteringVisible(false, for: .popover)
        popupLayout.endPresentation()
    }

    /// 仅在浮层显示期间监听外部点击；本地菜单仍可正常跟踪，不拦截原始事件。
    private func installDismissMonitors(generation: UInt64) {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !self.isStatusItemClick(event) else { return }
                // 全局鼠标监听在主线程调用；同一事件内完成关闭，避免排队到下一次打开后。
                self.dismissIfCurrent(generation)
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleLocalClick(event) }
            return event
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                               object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid() else { return }
            Task { @MainActor in self?.dismissIfCurrent(generation) }
        }
    }

    private func dismissIfCurrent(_ generation: UInt64) {
        guard generation == presentationGeneration else { return }
        hidePopup()
    }

    private func handleLocalClick(_ event: NSEvent) {
        if event.window === popup || event.window?.parent === popup { return }
        // 左右键均交给按钮的统一路由；监听器只负责真正的外部点击。
        if isStatusItemClick(event) { return }
        if let window = event.window, window.level >= .popUpMenu { return }
        hidePopup()
    }

    private func removeDismissMonitors() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        globalClickMonitor = nil
        localClickMonitor = nil
        activationObserver = nil
    }

    private func isStatusItemClick(_ event: NSEvent) -> Bool {
        guard let button = statusItem.button, let window = button.window else { return false }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return StatusItemInteraction.hitsButton(event: event, buttonFrame: frame)
    }

    @objc private func handleStatusItemAction() {
        let event = NSApp.currentEvent
        switch StatusItemInteraction.action(eventType: event?.type, modifiers: event?.modifierFlags ?? [],
                                            popupPresented: popupPresented) {
        case .showPanel: showPopup()
        case .hidePanel: hidePopup()
        case .showMenu: showStatusItemMenu()
        case nil: break
        }
    }

    private func showStatusItemMenu() {
        guard let button = statusItem.button else { return }
        // 右键只叠加菜单，不关闭已展开的主面板；关闭菜单后保留原页签和窗口位置。
        // 右键仅提供打开、设置与退出；不混入偏好开关和禁用的信息项。
        let menu = StatusItemMenu.make(openPanel: { [weak self] in self?.showPopup() },
                                       openSettings: { [weak self] in self?.showSettings() },
                                       quit: { NSApp.terminate(nil) },
                                       language: AppSettings.shared.resolvedLanguage)
        // 临时交给 NSStatusItem 的原生菜单路径，由 AppKit 选择屏幕、菜单栏下方的位置和高亮。
        // 普通 NSMenu.popUp 是视图弹出菜单，不具备状态栏菜单的锚定行为，可能覆盖菜单栏。
        statusItem.menu = menu
        defer {
            // 菜单跟踪结束即移除，保留左键打开浮层的既有行为。
            statusItem.menu = nil
            button.highlight(popupPresented)
        }
        button.performClick(nil)
    }

    private var settingsWindowTitle: String {
        L10n.text("Aural 设置", language: AppSettings.shared.resolvedLanguage)
    }

    private func updateStatusItemBattery() {
        guard let button = statusItem.button else { return }
        let enabled = AppSettings.shared.showCurrentDeviceBattery
        let battery = model.headphones.battery
        button.title = StatusItemBatteryText.title(enabled: enabled, percent: battery)
        if enabled, let battery {
            button.toolTip = "Aural · 当前设备电量 \(battery)% · 左键打开/收起，右键更多操作"
            button.setAccessibilityValue("当前设备电量 \(battery)%")
        } else {
            button.toolTip = "Aural · 左键打开/收起，右键更多操作"
            button.setAccessibilityValue(nil)
        }
    }

    private func updateSettingsWindowTitle() {
        settingsWindow?.title = settingsWindowTitle
    }
}

extension StatusPanelController: NSWindowDelegate {
    func windowDidChangeOcclusionState(_ notification: Notification) {
        if notification.object as? NSWindow === popup, popupPresented,
           !popup.isVisible || NSApp.isHidden { hidePopup() }
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === popup { hidePopup(); return }
        if notification.object as? NSWindow === settingsWindow {
            AuralUpdateChecker.shared.resetSettingsPresentation()
        }
    }
}
/// 顶栏 44、标签区 36、页脚 34；显示时按当前屏幕的可用高度限制外框。
/// 测量的是中部完整内容，最小高度只给视口留余量，不放大每行控件。
enum PanelMetrics {
    // 与 Magpie 的 panelWidth 保持一致，菜单栏浮层使用 440pt 标准宽度。
    static let width: CGFloat = 440
    static let minimumHeight: CGFloat = 300
    /// 未展示的初始布局使用这个尺寸预算；展示时由控制器注入实际屏幕上限。
    static let maximumContentHeight: CGFloat = 560
    static let chromeHeight: CGFloat = 114
    static let contentWidth: CGFloat = width - 24
    // 主面板所有左右留白只由这一个常量决定；行内 padding 是唯一水平入口，
    // 外层容器不再叠加水平留白，避免左边出现双重缩进而右边只有一层。
    static let horizontalInset: CGFloat = 12
    static let deviceRowHeight: CGFloat = 40
    static let deviceSelectionWidth: CGFloat = 176
    static let compactSliderMinimumWidth: CGFloat = 136

    /// 独立窗口内容变化时保持左上角；不以中心缩放，也不让页脚变化带动整个窗口左右漂移。
    static func resizedWindowFrame(_ current: CGRect, size: CGSize) -> CGRect {
        CGRect(x: current.minX, y: current.maxY - size.height, width: size.width, height: size.height)
    }

    static func viewportHeight(contentHeight: CGFloat,
                               maximumHeight: CGFloat = chromeHeight + maximumContentHeight) -> CGFloat {
        // 小屏幕也不能被最小高度挤出屏幕；自然内容始终测全，只限制最终视口。
        let available = max(0, floor(maximumHeight) - chromeHeight)
        return min(max(minimumHeight - chromeHeight, ceil(contentHeight)), available)
    }

    static func size(contentHeight: CGFloat,
                     maximumHeight: CGFloat = chromeHeight + maximumContentHeight) -> CGSize {
        CGSize(width: width,
               height: viewportHeight(contentHeight: contentHeight, maximumHeight: maximumHeight) + chromeHeight)
    }
}


