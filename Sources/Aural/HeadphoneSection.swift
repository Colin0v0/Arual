import SwiftUI
import AuralCore

/// 每副耳机有独立卡片和控制器，布局不再提供互斥的目标选择器。
struct HeadphoneControlsSection: View {
    @ObservedObject var group: HeadphoneControllerGroup
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if group.entries.isEmpty {
                Text(L10n.text("当前输出路由中没有可控制的耳机", language: language))
                    .font(PanelStyle.captionFont).foregroundStyle(PanelStyle.secondary).padding(12)
            }
            ForEach(group.entries) { entry in
                HeadphoneSection(controller: entry.controller, output: entry.output)
                if entry.id != group.entries.last?.id { PanelDivider() }
            }
        }
    }
}

struct HeadphoneSection: View {
    @ObservedObject var controller: HeadphoneController
    let output: AudioOutput?
    @Environment(\.appLanguage) private var language

    private var canScan: Bool {
        switch controller.phase {
        case .idle, .failed, .choosing: return true
        default: return false
        }
    }
    private var outputIsSupported: Bool {
        controller.supports(output)
    }

    private var connectionActionTitle: String {
        switch controller.phase {
        case .failed: return L10n.text("重试", language: language)
        case .choosing: return L10n.text("重新扫描", language: language)
        default: return L10n.text("启用耳机控制", language: language)
        }
    }

    private var hasDetails: Bool {
        // 不支持耳机控制时只保留标题和禁用按钮，不再撑出空的详情区域。
        controller.phase == .ready || controller.errorMessage != nil
    }

    private var connectionStatusTitle: String {
        if !controller.isRouteAuthorized { return L10n.text("正在切换音频路由…", language: language) }
        if controller.isAwaitingWear { return L10n.text("未佩戴，戴回后恢复控制", language: language) }
        // 不展示广播候选列表，也不在身份不明确时任意选择一副耳机。
        if controller.isControlSuppressed { return L10n.text("耳机控制已暂停", language: language) }
        return controller.phase == .choosing
            ? L10n.text("无法确定当前耳机，请重新扫描", language: language)
            : L10n.text(controller.phase.title, language: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(12)
                // 只有提示或已连接控制项才占用下一块，扫描结果不再撑出额外列表。
                if hasDetails {
                    PanelDivider().padding(.leading, PanelMetrics.horizontalInset)
                    VStack(alignment: .leading, spacing: 10) {
                        if let error = controller.errorMessage {
                            // 真实错误只显示一次；不把连接失败伪装成未连接的正常状态。
                            PanelError(text: error)
                        }
                        if controller.phase == .ready {
                            connectedControls
                        }
                    }.padding(10)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "headphones").font(.system(size: 20, weight: .light)).frame(width: 24, height: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(controller.displayName, language: language)).font(PanelStyle.bodyFont)
                if controller.errorMessage == nil {
                    Text(connectionStatusTitle).font(PanelStyle.captionFont).foregroundStyle(PanelStyle.secondary)
                }
            }
            Spacer()
            if controller.state.isCharging == true {
                // 仅在耳机明确报告充电时显示，未读取不等于未充电。
                Image(systemName: "bolt.fill")
                    .foregroundStyle(PanelStyle.secondary)
                    .accessibilityLabel(L10n.text("正在充电", language: language))
            }
            if let battery = controller.state.battery {
                // 不用假的满电图标表达电量，百分比完全来自耳机的确认响应。
                Text("\(battery)%").monospacedDigit().foregroundStyle(PanelStyle.secondary)
                    .accessibilityLabel(L10n.format("耳机电量 %d%%", language: language,
                                                    arguments: [battery]))
            }
            if controller.isReconnecting || (!canScan && controller.phase != .ready && controller.phase != .disconnecting) {
                ProgressView().controlSize(.small).accessibilityLabel(controller.phase.title)
            }
            if controller.phase != .ready {
                // 名称与状态保留在左侧，连接、重试和取消统一放在同一行右侧。
                connectionAction.fixedSize()
            }
        }
    }


    private var connectedControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let actual = controller.state.noiseMode, !controller.supportedNoiseModes.isEmpty {
                PanelTabs(items: controller.supportedNoiseModes, selection: actual,
                          title: { L10n.text($0.title, language: language) }) { mode in
                    controller.setNoiseMode(mode)
                }
                .disabled(controller.busy || !controller.isRouteAuthorized)
                .accessibilityLabel(L10n.text("耳机噪声控制", language: language))
                // 点击不预先修改选中项；只有 SET 成功且 GET 匹配后，白色块才移动。
            }
            if controller.supportedNoiseModes.isEmpty {
                Text(L10n.text("该耳机尚未确认噪声控制能力", language: language))
                    .foregroundStyle(PanelStyle.secondary)
            }
            HStack {
                // 刷新期间在原按钮里显示加载圈，保留固定宽度，不挤动旁边的操作。
                PanelActionButton(L10n.text("刷新", language: language),
                                  isLoading: controller.busy) { controller.refresh() }
                    .disabled(!controller.isRouteAuthorized)
                Spacer()
                if controller.canDisconnect {
                    PanelActionButton(L10n.text("停止控制", language: language)) { controller.disconnect() }
                }
            }
        }
    }

    @ViewBuilder
    private var connectionAction: some View {
        if controller.isAwaitingWear {
            Text(L10n.text("等待佩戴", language: language)).foregroundStyle(PanelStyle.secondary)
        } else if controller.isReconnecting {
            Button(L10n.text("取消重连", language: language)) { controller.disconnect() }
                .buttonStyle(PanelButtonStyle())
        } else if canScan {
            Button(connectionActionTitle) {
                if let output { controller.retryAutomaticConnection(output: output) }
            }.buttonStyle(PanelButtonStyle(prominent: true)).disabled(!outputIsSupported)
                .help(L10n.text("选择支持的蓝牙耳机作为系统输出后会自动连接", language: language))
        } else if controller.phase != .disconnecting {
            PanelActionButton(L10n.text("取消", language: language)) { controller.disconnect() }
        } else {
            ProgressView().controlSize(.small)
                .accessibilityLabel(L10n.text("正在断开耳机", language: language))
        }
    }
}
