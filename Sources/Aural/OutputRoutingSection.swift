import SwiftUI
import AuralCore

/// 视图只保留展开状态，成员选择与实际播放完全来自模型。
@MainActor
final class OutputRoutingDisclosure: ObservableObject {
    @Published var isChoosing = false
    func cancel() { isChoosing = false }
}

/// 同时输出错误与关闭按钮共用操作按钮高度，文字块和按钮始终沿同一水平中心线排列。
struct OutputRoutingErrorRow: View {
    let text: String
    let canDismiss: Bool
    let dismiss: () -> Void
    @Environment(\.appLanguage) private var language

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            PanelError(text: text)
                .frame(maxWidth: .infinity, minHeight: PanelActionMetrics.size, alignment: .leading)
            if canDismiss {
                PanelActionButton(systemName: "xmark",
                                  title: L10n.text("关闭同时输出提示", language: language),
                                  action: dismiss)
            }
        }
        .frame(minHeight: PanelActionMetrics.size)
        .padding(.horizontal, 12)
    }
}

struct OutputRoutingSection: View {
    let audio: SystemAudioSnapshot
    let routing: OutputRoutingState
    private var route: MultiOutputRoute? { routing.confirmed?.aggregate }
    private var error: String? { routing.error }
    let select: (UInt32) -> Void
    let setVolume: (Float, UInt32) -> Void
    let setMuted: (Bool, UInt32) -> Void
    let stop: () -> Void
    let dismissError: () -> Void
    var setSimultaneousVolume: (Float) -> Void = { _ in }
    var setSimultaneousMuted: (Bool) -> Void = { _ in }
    let toggleMember: (String) -> Void
    // 预览和独立测试可以显式保留入口；真实运行值始终由 AppSettings 注入。
    var showSimultaneousOutput = true
    @StateObject private var selection = OutputRoutingDisclosure()
    @Environment(\.appLanguage) private var language

    private var unmanagedOutputs: [AudioOutput] {
        routing.pendingCleanup
    }

    private var selectedUnmanagedOutput: Bool { unmanagedOutputs.contains { $0.id == audio.selectedID } }

    private var simultaneousUIDs: Set<String> {
        guard let route, route.deviceID == audio.selectedID else { return [] }
        return Set(route.outputs.map(\.uid))
    }

    private var selectedUIDs: Set<String> {
        routing.isSimultaneous ? Set(routing.selectedMemberUIDs) : []
    }

    /// 组合行使用所有成员共同可写的控制；成员能力不一致时明确禁用统一控制。
    private var simultaneousControl: SimultaneousOutputControl? {
        guard routing.isSimultaneous, let confirmed = routing.confirmed else { return nil }
        let outputs = confirmed.aggregate?.outputs ?? [confirmed.output]
        var volumes: [AudioDeviceVolume] = []
        var mutes: [AudioDeviceMute] = []
        for output in outputs {
            guard case .available(let volume, let mute) = audio.controls[output.id] else {
                return SimultaneousOutputControl(scalar: nil, volumeWritable: false,
                                                 muted: nil, muteWritable: false)
            }
            volumes.append(volume)
            mutes.append(mute)
        }
        let scalars = volumes.compactMap(\.scalar)
        let scalar = scalars.count == volumes.count ? scalars.reduce(0, +) / Float(scalars.count) : nil
        let muted: Bool?
        if mutes.allSatisfy({ $0.muted == true }) { muted = true }
        else if mutes.allSatisfy({ $0.muted == false }) { muted = false }
        else { muted = nil }
        return SimultaneousOutputControl(scalar: scalar,
                                         volumeWritable: scalar != nil && volumes.allSatisfy(\.writable),
                                         muted: muted,
                                         muteWritable: mutes.allSatisfy(\.writable))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !unmanagedOutputs.isEmpty {
                Text(selectedUnmanagedOutput
                     ? L10n.text("选择一台扬声器继续播放", language: language)
                     : L10n.text("上次的同时输出还在，清理后可重新设置", language: language))
                    .font(PanelStyle.captionFont).foregroundStyle(PanelStyle.secondary).padding(.horizontal, 12)
            }
            if routing.phase.isBusy {
                Text(L10n.text("正在等待系统确认输出…", language: language))
                    .font(PanelStyle.captionFont).foregroundStyle(PanelStyle.secondary).padding(.horizontal, 12)
            }
            if routing.phase == .awaitingMembers {
                Text(L10n.text("已选设备均暂不可用，等待原设备恢复", language: language))
                    .font(PanelStyle.captionFont).foregroundStyle(PanelStyle.secondary).padding(.horizontal, 12)
            } else if !routing.phase.isBusy, routing.confirmed != nil, !routing.unavailableMemberUIDs.isEmpty {
                Text(L10n.text("部分设备暂不可用，正通过其余已选设备播放；恢复后自动加入", language: language))
                    .font(PanelStyle.captionFont).foregroundStyle(PanelStyle.secondary).padding(.horizontal, 12)
            }
            if let warning = routing.warning {
                Text(L10n.text(warning, language: language))
                    .font(PanelStyle.captionFont).foregroundStyle(PanelStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }
            if let error {
                OutputRoutingErrorRow(text: L10n.text(error, language: language),
                                      canDismiss: route == nil && unmanagedOutputs.isEmpty,
                                      dismiss: dismissError)
                if let actual = routing.actualOutput {
                    Text(L10n.format("实际输出：%@", language: language, arguments: [actual.name]))
                        .font(PanelStyle.captionFont).foregroundStyle(PanelStyle.secondary).padding(.horizontal, 12)
                }
                if let systemID = routing.actualSystemOutputID,
                   systemID != routing.actualOutput?.id,
                   let systemOutput = audio.outputs.first(where: { $0.id == systemID }) {
                    Text(L10n.format("提示音输出：%@", language: language, arguments: [systemOutput.name]))
                        .font(PanelStyle.captionFont).foregroundStyle(PanelStyle.secondary).padding(.horizontal, 12)
                }
                if !routing.completedSteps.isEmpty {
                    Text(routing.completedSteps.map { L10n.text($0, language: language) }.joined(separator: " · "))
                        .font(PanelStyle.captionFont).foregroundStyle(PanelStyle.secondary).padding(.horizontal, 12)
                }
            }
            if selection.isChoosing {
                // 展开仅显示模型确认的成员，不构造另一份播放草稿。
                VStack(alignment: .leading, spacing: 0) {
                    routingList
                    SimultaneousOutputEditor(
                        outputs: audio.outputs + routing.configuredOutputs.filter { configured in
                            !audio.outputs.contains { $0.uid == configured.uid }
                        }, controls: audio.controls,
                        selectedUIDs: selectedUIDs, toggleMember: toggleMember,
                        setVolume: setVolume, setMuted: setMuted
                    )
                }
            } else {
                routingList
            }
        }
        .onChange(of: unmanagedOutputs.map(\.uid)) { _, uids in
            if !uids.isEmpty { selection.cancel() }
        }
        .onChange(of: showSimultaneousOutput) { _, shown in
            if !shown, selection.isChoosing {
                selection.cancel()
            }
        }
    }

    /// 设备行与同时输出行共享零间距列表，保证分隔线位置不额外下移。
    private var routingList: some View {
        VStack(alignment: .leading, spacing: 0) {
            OutputDevicesSection(audio: audio, select: selectDeviceFromPhysicalList,
                                 setVolume: setVolume, setMuted: setMuted,
                                 simultaneousUIDs: simultaneousUIDs,
                                 selectionSuppressed: routing.isSimultaneous,
                                 hiddenUID: route?.uid)
            if let route {
                SimultaneousOutputRow(
                    title: L10n.format("多设备输出 · %d 台", language: language,
                                       arguments: [route.outputs.count]),
                    selected: true,
                    expanded: selection.isChoosing,
                    control: simultaneousControl,
                    toggle: toggleEditor,
                    setVolume: setSimultaneousVolume,
                    setMuted: setSimultaneousMuted
                )
                .help(route.outputs.map(\.name).joined(separator: "\n"))
            } else if routing.isSimultaneous {
                SimultaneousOutputRow(
                    title: L10n.text("同时输出设备", language: language), selected: true,
                    expanded: selection.isChoosing, control: simultaneousControl,
                    toggle: toggleEditor, setVolume: setSimultaneousVolume, setMuted: setSimultaneousMuted
                )
            } else if !unmanagedOutputs.isEmpty {
                // 没有上一轮的原输出记录时，必须先由用户选择真实设备。
                if !selectedUnmanagedOutput {
                    HStack(spacing: 7) {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                            .foregroundStyle(PanelStyle.secondary)
                            .accessibilityHidden(true)
                        PanelActionButton(L10n.text("清理残留设备", language: language), action: stop)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: PanelMetrics.deviceRowHeight)
                }
            } else if showSimultaneousOutput {
                SimultaneousOutputRow(
                    title: L10n.text("同时输出设备", language: language),
                    selected: false,
                    expanded: selection.isChoosing,
                    control: nil,
                    toggle: toggleEditor,
                    setVolume: { _ in },
                    setMuted: { _ in }
                )
            }
        }
    }

    private func toggleEditor() {
        // 展示行为不调用停止、释放或选择输出；单成员模式折叠后仍保持蓝色并继续播放。
        selection.isChoosing.toggle()
    }

    /// 上方真实设备行的语义始终是“切换为单一输出”；点击时立即收起多输出草稿，避免两套选择状态并存。
    private func selectDeviceFromPhysicalList(_ id: UInt32) {
        if selection.isChoosing {
            selection.cancel()
        }
        select(id)
    }
}

/// 向下展开的成员选择沿用当前勾选顺序，并允许只启用一台设备。
struct SimultaneousOutputEditor: View {
    let outputs: [AudioOutput]
    let controls: [UInt32: AudioDeviceControlState]
    let selectedUIDs: Set<String>
    let toggleMember: (String) -> Void
    let setVolume: (Float, UInt32) -> Void
    let setMuted: (Bool, UInt32) -> Void
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Self.visibleOutputs(outputs: outputs, controls: controls, selectedUIDs: selectedUIDs)) { output in
                SimultaneousOutputDeviceRow(
                    output: output,
                    control: controls[output.id],
                    selected: selectedUIDs.contains(output.uid),
                    toggle: { toggleMember(output.uid) },
                    setVolume: { setVolume($0, output.id) },
                    setMuted: { setMuted($0, output.id) }
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(PanelStyle.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).strokeBorder(PanelStyle.line.opacity(0.8), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    /// 同时输出列表只提供可调音量的真实硬件；已选中的旧成员仍保留，以便用户明确移除。
    static func visibleOutputs(outputs: [AudioOutput],
                               controls: [UInt32: AudioDeviceControlState],
                               selectedUIDs: Set<String>) -> [AudioOutput] {
        outputs.filter { output in
            guard output.supportsSimultaneousOutput else { return false }
            if selectedUIDs.contains(output.uid) { return true }
            guard case .available(let volume, _) = controls[output.id] else { return false }
            return volume.scalar != nil && volume.writable
        }
    }
}

/// 成员行同时提供勾选与独立硬件音量；顶部聚合音量仍负责统一调节全部成员。
private struct SimultaneousOutputDeviceRow: View {
    let output: AudioOutput
    let control: AudioDeviceControlState?
    let selected: Bool
    let toggle: () -> Void
    let setVolume: (Float) -> Void
    let setMuted: (Bool) -> Void
    @Environment(\.appLanguage) private var language

    private func muteDescription(_ mute: AudioDeviceMute) -> String {
        guard let muted = mute.muted else { return L10n.text("设备未公开静音状态", language: language) }
        return L10n.text(muted ? "已静音" : "未静音", language: language)
    }

    private func muteSymbol(_ mute: AudioDeviceMute) -> String {
        mute.muted == true ? "speaker.slash" : "speaker.wave.2"
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(selected ? PanelStyle.accent : PanelStyle.secondary)
                    Image(systemName: output.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? PanelStyle.accent : PanelStyle.secondary)
                        .frame(width: 22, height: 22)
                        .background(PanelStyle.iconSurface, in: RoundedRectangle(cornerRadius: 5))
                    Text(output.name)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .foregroundStyle(PanelStyle.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 190, alignment: .leading)
            .accessibilityLabel(L10n.format(selected ? "从同时输出移除：%@" : "加入同时输出：%@",
                                            language: language, arguments: [output.name]))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(L10n.format(selected ? "从同时输出移除“%@”" : "将“%@”加入同时输出",
                              language: language, arguments: [output.name]))

            switch control {
            case .available(let volume, let mute):
                PanelActionButton(systemName: muteSymbol(mute),
                                  title: L10n.format("%@ 静音", language: language, arguments: [output.name]),
                                  tint: mute.muted == true ? .red : nil,
                                  hoverStyle: .foregroundOnly,
                                  action: {
                    if let muted = mute.muted { setMuted(!muted) }
                })
                .disabled(!mute.writable)
                .accessibilityValue(muteDescription(mute))
                .help(mute.writable
                      ? L10n.format("切换“%@”静音", language: language, arguments: [output.name])
                      : L10n.text("设备未公开可写的硬件静音控制", language: language))
                if let scalar = volume.scalar {
                    PanelVolumeSlider(value: Binding(get: { Double(scalar) }, set: { setVolume(Float($0)) }),
                                      label: L10n.format("%@ 的同时输出音量", language: language,
                                                         arguments: [output.name]))
                        .frame(minWidth: 72)
                        .disabled(!volume.writable)
                        .help(volume.writable
                              ? L10n.format("调节“%@”独立音量；不会切换默认输出", language: language,
                                            arguments: [output.name])
                              : L10n.text("设备音量只读", language: language))
                    PanelPercentage(value: scalar)
                } else {
                    Text(L10n.text("不支持系统音量", language: language))
                        .font(PanelStyle.captionFont)
                        .foregroundStyle(PanelStyle.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            case .failed(let message):
                Label(L10n.text("读取失败", language: language), systemImage: "exclamationmark.circle")
                    .font(PanelStyle.captionFont)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(message)
            case nil:
                Text(L10n.text("尚未读取设备控制状态", language: language))
                    .font(PanelStyle.captionFont)
                    .foregroundStyle(PanelStyle.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: PanelMetrics.deviceRowHeight)
    }
}

/// 组合输出的统一控制在所有成员都可写时才生效，不使用单个成员冒充整体状态。
struct SimultaneousOutputControl: Equatable {
    let scalar: Float?
    let volumeWritable: Bool
    let muted: Bool?
    let muteWritable: Bool
}

/// 与普通设备行保持相同的图标、选择区和音量控件，通过标题区向下展开成员选择。
struct SimultaneousOutputRow: View {
    let title: String
    let selected: Bool
    let expanded: Bool
    let control: SimultaneousOutputControl?
    let toggle: () -> Void
    let setVolume: (Float) -> Void
    let setMuted: (Bool) -> Void
    @Environment(\.appLanguage) private var language

    var body: some View {
        Group {
            if let control {
                HStack(spacing: 10) {
                    Button(action: toggle) { identity }
                        .buttonStyle(.plain)
                        .frame(width: PanelMetrics.deviceSelectionWidth, alignment: .leading)
                        .accessibilityLabel(title)
                        .accessibilityHint(L10n.text(expanded ? "收起同时输出设备" : "展开并更改同时输出设备",
                                                     language: language))
                        .accessibilityAddTraits(selected ? .isSelected : [])

                    PanelActionButton(systemName: control.muted == true ? "speaker.slash" : "speaker.wave.2",
                                      title: L10n.text(control.muted == true ? "取消同时输出静音" : "静音同时输出",
                                                       language: language),
                                      tint: control.muted == true ? .red : nil,
                                      hoverStyle: .foregroundOnly) {
                        setMuted(control.muted != true)
                    }
                    .disabled(!control.muteWritable)

                    if let scalar = control.scalar {
                        PanelVolumeSlider(value: Binding(get: { Double(scalar) }, set: { setVolume(Float($0)) }),
                                          label: L10n.text("同时输出总音量", language: language))
                            .frame(minWidth: PanelMetrics.compactSliderMinimumWidth)
                            .disabled(!control.volumeWritable)
                        PanelPercentage(value: scalar)
                    } else {
                        Text(L10n.text("不支持统一音量", language: language))
                            .font(PanelStyle.captionFont)
                            .foregroundStyle(PanelStyle.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // 未启用时整行就是设置入口，不再额外放一个“设置”文字。
                Button(action: toggle) {
                    HStack(spacing: 10) {
                        identity
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityHint(L10n.text(expanded ? "收起同时输出设备" : "展开并更改同时输出设备",
                                             language: language))
            }
        }
        .frame(height: PanelMetrics.deviceRowHeight)
        .font(PanelStyle.bodyFont)
    }

    private var identity: some View {
        HStack(spacing: 8) {
            AudioDeviceIcon(symbol: "rectangle.on.rectangle", selected: selected)
            Text(title).lineLimit(1).foregroundStyle(PanelStyle.ink)
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(PanelStyle.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
