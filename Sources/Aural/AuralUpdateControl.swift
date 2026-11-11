import SwiftUI

enum AuralUpdatePresentation {
    case capsule
    case text
}

/// 主面板和设置页共享同一个更新胶囊，避免两处状态文案和操作不一致。
struct AuralUpdateCapsule: View {
    @ObservedObject var updates: AuralUpdateChecker
    @ObservedObject var settings: AppSettings
    var presentation: AuralUpdatePresentation = .capsule

    var body: some View {
        if let update = updates.availableUpdate {
            AuralUpdateBadge(phase: updates.phase,
                             version: update.version,
                             language: settings.resolvedLanguage,
                             action: primaryAction,
                             skip: updates.skipAvailableUpdate,
                             presentation: presentation)
            .help(helpText(update: update))
            .accessibilityLabel(settings.localizedFormat("更新到 %@", update.version))
        }
    }

    private func primaryAction() {
        switch updates.phase {
        case .available, .failed:
            updates.downloadAndPrepare()
        case .ready:
            updates.restartAndInstall()
        case .idle, .downloading, .preparing:
            break
        }
    }

    private func helpText(update: AuralAvailableUpdate) -> String {
        if let error = updates.lastError {
            return settings.localizedFormat("更新到 %@ 失败：%@", update.version, error)
        }
        return settings.localizedFormat("更新到 %@", update.version)
    }
}
/// 更新胶囊只表达状态；网络、校验和安装逻辑仍由 AuralUpdateChecker 持有。
struct AuralUpdateBadge: View {
    let phase: AuralUpdatePhase
    let version: String
    let language: AppLanguage
    let action: () -> Void
    let skip: () -> Void
    var presentation: AuralUpdatePresentation = .capsule
    @StateObject private var hover = HoverState()
    private final class HoverState: ObservableObject {
        @Published var active = false
    }

    var body: some View {
        if Self.usesTextPresentation(phase, presentation: presentation) {
            textPrompt
        } else {
            capsulePrompt
        }
    }

    /// 静止的“发现更新”只占用一行文字；下载、准备和重启仍用胶囊表达进度。
    private var textPrompt: some View {
        HStack(spacing: 5) {
            Button(action: action) {
                Text(availableTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hover.active ? PanelStyle.ink : PanelStyle.secondary)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if canSkip {
                Button(action: skip) {
                    Image(systemName: "xmark")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(PanelStyle.secondary)
                        .frame(width: 12, height: 12)
                        .background(PanelStyle.surface, in: Circle())
                        .overlay { Circle().strokeBorder(PanelStyle.line, lineWidth: 1) }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L10n.format("跳过 %@", language: language, arguments: [version]))
                .accessibilityLabel(L10n.format("跳过 %@", language: language, arguments: [version]))
            }
        }
        .frame(height: 18)
        .onHover { hover.active = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.active)
    }

    private var capsulePrompt: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(height: 25)
            .background(Capsule().fill(fill))
            .overlay { Capsule().strokeBorder(border, lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // 忙碌状态仍要清晰可读；action 本身会忽略下载和准备阶段的点击。
        .allowsHitTesting(!isBusy)
        .accessibilityValue(isBusy ? L10n.text("进行中", language: language) : "")
        .onHover { hover.active = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.active)
        .overlay(alignment: .topTrailing) {
            if canSkip {
                Button(action: skip) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(PanelStyle.secondary)
                        .frame(width: 14, height: 14)
                        .background(PanelStyle.surface, in: Circle())
                        .overlay { Circle().strokeBorder(PanelStyle.line, lineWidth: 1) }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L10n.format("跳过 %@", language: language, arguments: [version]))
                .accessibilityLabel(L10n.format("跳过 %@", language: language, arguments: [version]))
                // 关闭入口只在胶囊右上角轻微外露，不占据正文高度。
                .offset(x: 5, y: -5)
            }
        }
        // 叉号超出胶囊时不能被裁切；只有可跳过状态才占用视觉空间。
        .padding(.top, canSkip ? 5 : 0)
        .padding(.trailing, canSkip ? 5 : 0)
    }

    private var canSkip: Bool { Self.showsDismiss(phase) }

    /// 设置页的静态可更新状态使用文字；主面板始终保留紫色胶囊入口。
    static func usesTextPresentation(_ phase: AuralUpdatePhase,
                                     presentation: AuralUpdatePresentation) -> Bool {
        presentation == .text && phase == .available
    }

    /// 只有用户可决定“暂不更新”的静止状态才显示关闭入口。
    static func showsDismiss(_ phase: AuralUpdatePhase) -> Bool {
        switch phase {
        case .available, .failed: return true
        case .downloading, .preparing, .ready, .idle: return false
        }
    }

    private var isBusy: Bool {
        switch phase {
        case .downloading, .preparing: return true
        case .available, .ready, .failed, .idle: return false
        }
    }

    private var solid: Bool {
        if case .ready = phase { return true }
        if case .failed = phase { return false }
        return hover.active && !isBusy
    }

    private var fill: Color {
        if case .failed = phase { return PanelStyle.error.opacity(0.08) }
        return solid ? PanelStyle.updateSolid : PanelStyle.updateFill
    }

    private var border: Color {
        if case .failed = phase { return PanelStyle.error.opacity(0.35) }
        return solid ? PanelStyle.updateSolid : PanelStyle.updateBorder
    }

    private var foreground: Color {
        if case .failed = phase { return PanelStyle.error }
        return solid ? PanelStyle.updateSolidInk : PanelStyle.updateInk
    }

    private var iconName: String {
        if case .failed = phase { return "arrow.clockwise" }
        return "arrow.up"
    }

    private var title: String {
        switch phase {
        case .available, .idle:
            return L10n.text("更新", language: language)
        case .downloading(let progress):
            let percent = Int((progress * 100).rounded())
            return percent > 0
                ? L10n.format("正在下载 %d%%", language: language, arguments: [percent])
                : L10n.text("正在下载…", language: language)
        case .preparing:
            return L10n.text("更新中…", language: language)
        case .ready:
            return L10n.text("重启以更新", language: language)
        case .failed:
            return L10n.text("重试更新", language: language)
        }
    }

    private var availableTitle: String {
        L10n.format("发现新版本 %@", language: language, arguments: [version])
    }
}
