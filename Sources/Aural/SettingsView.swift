import SwiftUI
import AuralCore
import ServiceManagement

/// 登录项状态来自系统服务，错误只在当前设置窗口展示。
@MainActor
private final class LoginItemState: ObservableObject {
    @Published var enabled = SMAppService.mainApp.status == .enabled
    @Published var error: String?
}

/// 独立窗口只承载产品设置，不再复制主面板的设备控制。
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject private var updates = AuralUpdateChecker.shared
    @StateObject private var loginItem = LoginItemState()
    @StateObject private var updateCheckHover = PanelRowHoverState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            generalCard
            featuresCard
            Spacer(minLength: 0)
            footer
        }
        .padding(SettingsMetrics.horizontalInset)
        .frame(width: SettingsMetrics.width, height: SettingsMetrics.height, alignment: .topLeading)
        .background(PanelStyle.canvas)
        .foregroundStyle(PanelStyle.ink)
        .preferredColorScheme(settings.appearance.colorScheme)
        // 设置页内的分段控件也读取环境语言；在这里统一注入，避免标题已翻译而“关闭 / 开启”仍显示中文。
        .environment(\.appLanguage, settings.resolvedLanguage)
        .onChange(of: scenePhase) { _, phase in
            // 从系统设置返回时重新读取真实登录项状态，不用本地偏好冒充注册结果。
            if phase == .active {
                loginItem.enabled = SMAppService.mainApp.status == .enabled
            }
        }
        .alert(settings.localized("无法更改开机启动"), isPresented: Binding(
            get: { loginItem.error != nil },
            set: { if !$0 { loginItem.error = nil } }
        )) {
            Button(settings.localized("好"), role: .cancel) { loginItem.error = nil }
        } message: {
            Text(loginItem.error ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(PanelStyle.accent)
                .frame(width: 34, height: 34)
                .background(PanelStyle.surface, in: RoundedRectangle(cornerRadius: 9))
            Text(settings.localized("Aural 设置"))
                .font(.system(size: 16, weight: .semibold))
            Spacer()
        }
    }

    private var generalCard: some View {
        SettingsCard(title: settings.localized("通用")) {
            SettingsRow(title: settings.localized("界面语言")) {
                PanelSegmentedControl(items: AppLanguage.allCases, selection: $settings.language,
                                      title: languageTitle)
                .frame(width: SettingsMetrics.controlWidth)
            }
            PanelDivider()
            SettingsRow(title: settings.localized("外观")) {
                PanelSegmentedControl(items: AppAppearance.allCases, selection: $settings.appearance,
                                      title: appearanceTitle)
                .frame(width: SettingsMetrics.controlWidth)
            }
            PanelDivider()
            SettingsToggleRow(
                title: settings.localized("开机启动"),
                detail: settings.localized("登录 Mac 后自动运行 Aural。"),
                isOn: Binding(get: { loginItem.enabled }, set: setLaunchAtLogin)
            )
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        // 仅在用户操作时注册；首次运行不主动启用，也不创建额外启动脚本。
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItem.enabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            loginItem.enabled = SMAppService.mainApp.status == .enabled
            loginItem.error = error.localizedDescription
        }
    }

    private var featuresCard: some View {
        SettingsCard(title: settings.localized("功能")) {
            SettingsToggleRow(
                title: settings.localized("显示耳机控制页"),
                detail: settings.localized("关闭后，耳机控制从主面板隐藏。"),
                isOn: $settings.showHeadphoneControls
            )
            PanelDivider()
            SettingsToggleRow(
                title: settings.localized("显示多设备输出"),
                detail: settings.localized("关闭后，多设备输出功能从输出面板隐藏。"),
                isOn: simultaneousOutputBinding
            )
            PanelDivider()
            MenuBarBatterySettingsRow(settings: settings, group: model.headphones)
        }
    }

    private var footer: some View {
        HStack {
            Text("Aural \(AuralVersion.current)")
                .font(PanelStyle.captionFont)
                .foregroundStyle(PanelStyle.secondary)
            Spacer()
            if updates.availableUpdate != nil {
                AuralUpdateCapsule(updates: updates, settings: settings, presentation: .text)
            } else if updates.didCheckWithoutUpdate {
                Text(settings.localized("未发现新版本"))
                    .font(PanelStyle.captionFont)
                    .foregroundStyle(PanelStyle.secondary)
            } else if let error = updates.lastError {
                Button(settings.localized("检查失败，重试")) {
                    updates.check(force: true)
                }
                .buttonStyle(.plain)
                .font(PanelStyle.captionFont)
                .foregroundStyle(PanelStyle.error)
                .disabled(updates.isChecking)
                .help(error)
            } else {
                Button(settings.localized(updates.isChecking ? "正在检查更新…" : "检查更新")) {
                    updates.check(force: true)
                }
                .buttonStyle(.plain)
                .font(PanelStyle.captionFont)
                // 只变文字颜色，不增加悬停底板；检查中不呈现可点击的高亮。
                .foregroundStyle(updateCheckHover.active && !updates.isChecking
                                 ? PanelStyle.ink : PanelStyle.secondary)
                .onHover { updateCheckHover.active = $0 }
                .disabled(updates.isChecking)
            }
        }
    }

    private var simultaneousOutputBinding: Binding<Bool> {
        Binding(
            get: { settings.showSimultaneousOutput },
            set: { enabled in
                if enabled {
                    settings.showSimultaneousOutput = true
                    return
                }
                // 先完成真实资源释放；只有没有残留组合设备时才隐藏功能入口。
                model.stopSimultaneousOutput()
                if !model.outputRouting.phase.isBusy, model.outputRouting.phase != .failed,
                   model.outputRouting.pendingCleanup.isEmpty {
                    settings.showSimultaneousOutput = false
                }
            }
        )
    }

    private func languageTitle(_ language: AppLanguage) -> String {
        switch language {
        case .system: return settings.localized("跟随系统")
        case .chinese: return settings.localized("简体中文")
        case .english: return "English"
        }
    }

    private func appearanceTitle(_ appearance: AppAppearance) -> String {
        switch appearance {
        case .system: return settings.localized("跟随系统")
        case .light: return settings.localized("浅色")
        case .dark: return settings.localized("深色")
        }
    }
}

enum SettingsMetrics {
    // 分组标题、设置项与分隔线共用窗口留白，内层不再叠加缩进。
    static let horizontalInset: CGFloat = 18
    static let width: CGFloat = 500
    static let height: CGFloat = 470
    static let controlWidth: CGFloat = 238
    static let booleanControlWidth: CGFloat = 116
    static let rowHeight: CGFloat = 40
    static var size: CGSize { CGSize(width: width, height: height) }
}

struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PanelStyle.secondary)
                .padding(.bottom, 6)
            VStack(spacing: 0) {
                content()
            }
            // 内容与分组标题直接对齐，不再叠加原卡片的水平留白。
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: () -> Control

    init(title: String, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.control = control
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(PanelStyle.bodyFont)
            Spacer(minLength: 12)
            control()
        }
        // 标题和说明与分组标题使用同一左边缘。
        .frame(height: SettingsMetrics.rowHeight)
    }
}

struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    init(title: String, detail: String, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(PanelStyle.bodyFont)
                Text(detail)
                    .font(PanelStyle.captionFont)
                    .foregroundStyle(PanelStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            PanelBooleanControl(isOn: $isOn)
                .frame(width: SettingsMetrics.booleanControlWidth)
                .accessibilityLabel(title)
        }
        // 标题和说明与分组标题使用同一左边缘。
        .padding(.vertical, 8)
        .frame(minHeight: 52)
    }
}

/// 电量来源是单选而不是开关；固定目标断开时仍保留选择，但菜单栏不显示替代耳机。
struct MenuBarBatterySettingsRow: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var group: HeadphoneControllerGroup

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(settings.localized("菜单栏电量"))
                    .font(PanelStyle.bodyFont)
                Text(settings.localized("固定设备断开后隐藏。"))
                    .font(PanelStyle.captionFont)
                    .foregroundStyle(PanelStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            // 外壳继续使用设置页现有白底细边框；展开项交给原生 NSMenu，避免自制菜单的视觉与键盘行为偏差。
            BatterySourceMenu(
                title: title(for: settings.menuBarBatterySource),
                selected: settings.menuBarBatterySource,
                items: sourceMenuItems,
                onSelect: { settings.menuBarBatterySource = $0 }
            )
            // 标题有多长就展示多长，不再用固定 150pt 截断成省略号。
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(settings.localized("菜单栏电量"))
        }
        .padding(.vertical, 8)
        .frame(minHeight: 52)
    }

    private var sourceMenuItems: [BatterySourceMenu.Item] {
        var items = [
            BatterySourceMenu.Item(title: settings.localized("不显示"), source: .off),
            BatterySourceMenu.Item(title: settings.localized("跟随当前输出"), source: .currentOutput)
        ]
        for (index, entry) in group.entries.enumerated() {
            items.append(BatterySourceMenu.Item(
                title: settings.localizedFormat("固定：%@", entry.output.name),
                source: .pinned(deviceUID: entry.id),
                separatorBefore: index == 0
            ))
        }
        if let disconnectedPinnedSource {
            items.append(BatterySourceMenu.Item(
                title: title(for: disconnectedPinnedSource),
                source: disconnectedPinnedSource,
                enabled: false
            ))
        }
        return items
    }

    private func title(for source: MenuBarBatterySource) -> String {
        switch source {
        case .off:
            return settings.localized("不显示")
        case .currentOutput:
            return settings.localized("跟随当前输出")
        case .pinned(let deviceUID):
            guard let entry = group.entries.first(where: { $0.id == deviceUID }) else {
                return settings.localized("固定设备（未连接）")
            }
            return settings.localizedFormat("固定：%@", entry.output.name)
        }
    }

    private var disconnectedPinnedSource: MenuBarBatterySource? {
        guard case .pinned(let deviceUID) = settings.menuBarBatterySource,
              !group.entries.contains(where: { $0.id == deviceUID }) else { return nil }
        return settings.menuBarBatterySource
    }
}
