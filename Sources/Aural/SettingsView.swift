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
    @StateObject private var loginItem = LoginItemState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            generalCard
            featuresCard
            Spacer(minLength: 0)
            footer
        }
        .padding(18)
        .frame(width: SettingsMetrics.width, height: SettingsMetrics.height, alignment: .topLeading)
        .background(PanelStyle.canvas)
        .foregroundStyle(PanelStyle.ink)
        .preferredColorScheme(settings.appearance.colorScheme)
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
                Picker("", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(languageTitle(language)).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: SettingsMetrics.controlWidth)
            }
            PanelDivider()
            SettingsRow(title: settings.localized("外观")) {
                Picker("", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearanceTitle(appearance)).tag(appearance)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
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
        }
    }

    private var footer: some View {
        HStack {
            Text("Aural \(AuralVersion.current)")
                .font(PanelStyle.captionFont)
                .foregroundStyle(PanelStyle.secondary)
            Spacer()
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
                if model.multiOutputRoute == nil, model.unmanagedMultiOutputs.isEmpty {
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
    static let width: CGFloat = 500
    static let height: CGFloat = 430
    static let controlWidth: CGFloat = 238
    static let rowHeight: CGFloat = 40
    static var size: CGSize { CGSize(width: width, height: height) }
}

private struct SettingsCard<Content: View>: View {
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
            .padding(.horizontal, 12)
            .background(PanelStyle.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(PanelStyle.line.opacity(0.75), lineWidth: 1)
            }
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(PanelStyle.bodyFont)
            Spacer(minLength: 12)
            control()
        }
        .frame(height: SettingsMetrics.rowHeight)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

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
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 52)
    }
}
