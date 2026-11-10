import SwiftUI

/// 主面板和设置页共享同一个更新胶囊，避免两处状态文案和操作不一致。
struct AuralUpdateCapsule: View {
    @ObservedObject var updates: AuralUpdateChecker
    @ObservedObject var settings: AppSettings

    var body: some View {
        if let update = updates.availableUpdate {
            HStack(spacing: 0) {
                Button(action: primaryAction) {
                    HStack(spacing: 4) {
                        if isBusy {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.72)
                                .frame(width: 12, height: 12)
                                .tint(.white)
                        } else {
                            Image(systemName: iconName)
                                .font(.system(size: 10, weight: .semibold))
                        }
                        Text(title)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.leading, 9)
                    .padding(.trailing, 7)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isBusy)

                Rectangle()
                    .fill(Color.white.opacity(0.28))
                    .frame(width: 1, height: 13)

                Button(action: updates.skipAvailableUpdate) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 21, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(settings.localizedFormat("跳过 %@", update.version))
                .accessibilityLabel(settings.localizedFormat("跳过 %@", update.version))
            }
            .foregroundStyle(Color.white)
            .background(Capsule().fill(PanelStyle.accent))
            .fixedSize()
            .help(helpText(update: update))
        }
    }

    private var isBusy: Bool {
        switch updates.phase {
        case .downloading, .preparing: return true
        case .idle, .available, .ready, .failed: return false
        }
    }

    private var title: String {
        switch updates.phase {
        case .available: return settings.localized("更新")
        case .downloading(let progress):
            guard progress > 0 else { return settings.localized("下载中") }
            return "\(Int((progress * 100).rounded()))%"
        case .preparing: return settings.localized("准备中")
        case .ready: return settings.localized("重启以更新")
        case .failed: return settings.localized("重试更新")
        case .idle: return settings.localized("更新")
        }
    }

    private var iconName: String {
        switch updates.phase {
        case .available, .idle: return "arrow.down"
        case .downloading, .preparing: return "arrow.down"
        case .ready: return "arrow.clockwise"
        case .failed: return "exclamationmark.triangle.fill"
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
