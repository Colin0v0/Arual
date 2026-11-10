import SwiftUI
import AuralCore

/// 所有输出平铺显示，选择默认输出与修改各设备的硬件属性是互相独立的操作。
struct OutputDevicesSection: View {
    let audio: SystemAudioSnapshot
    let select: (UInt32) -> Void
    let setVolume: (Float, UInt32) -> Void
    let setMuted: (Bool, UInt32) -> Void
    var simultaneousUIDs: Set<String> = []
    /// 同时输出草稿已有成员时，真实设备行必须熄灯，由下方组合入口独占选中状态。
    var selectionSuppressed = false
    var hiddenUID: String? = nil
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(spacing: 0) {
            // 所有聚合输出都收进唯一的“同时输出设备”入口，列表里只保留真实硬件。
            ForEach(Self.visibleOutputs(audio.outputs, hiddenUID: hiddenUID)) { output in
                if let control = audio.controls[output.id] {
                    AudioDeviceRow(device: output, control: control,
                                    selected: Self.isSelected(output: output, selectedID: audio.selectedID,
                                                              simultaneousUIDs: simultaneousUIDs,
                                                              selectionSuppressed: selectionSuppressed),
                                    select: { select(output.id) }, setVolume: { setVolume($0, output.id) },
                                    setMuted: { setMuted($0, output.id) },
                                    selectionHint: simultaneousUIDs.isEmpty ? nil
                                        : L10n.format("结束同时输出，仅使用“%@”播放",
                                                      language: language, arguments: [output.name]))
                } else {
                    PanelError(text: L10n.format("%@ 尚未读取设备控制状态", language: language,
                                                 arguments: [output.name])).padding(12)
                }
            }
        }
    }

    /// 普通列表只呈现真实硬件；系统、第三方和 Aural 聚合设备都不再重复成行。
    static func visibleOutputs(_ outputs: [AudioOutput], hiddenUID: String?) -> [AudioOutput] {
        outputs.filter { !$0.isAggregate && $0.uid != hiddenUID }.sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.uid < rhs.uid
        }
    }

    /// 同时输出启用时，选中状态只属于下方聚合行；成员设备仍可单独调音量，但不是当前默认输出。
    static func isSelected(output: AudioOutput, selectedID: UInt32,
                           simultaneousUIDs: Set<String>,
                           selectionSuppressed: Bool = false) -> Bool {
        !selectionSuppressed && simultaneousUIDs.isEmpty && output.id == selectedID
    }
}

/// 不依赖 AppModel 的纯布局，可验证同名设备、只读属性和错误状态，而不接触真实硬件。
struct AudioDeviceRow<Device: AudioDeviceDescriptor>: View {
    let device: Device
    let control: AudioDeviceControlState
    let selected: Bool
    private var direction: AudioDeviceDirection { device.direction }
    let select: () -> Void
    let setVolume: (Float) -> Void
    let setMuted: (Bool) -> Void
    var selectionHint: String? = nil
    @Environment(\.appLanguage) private var language

    private func muteDescription(_ mute: AudioDeviceMute) -> String {
        guard let muted = mute.muted else { return L10n.text("设备未公开静音状态", language: language) }
        return L10n.text(muted ? "已静音" : "未静音", language: language)
    }

    private func muteSymbol(_ mute: AudioDeviceMute) -> String {
        if direction == .input { return mute.muted == true ? "mic.slash" : "mic" }
        return mute.muted == true ? "speaker.slash" : "speaker.wave.2"
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: select) {
                HStack(spacing: 8) {
                    AudioDeviceIcon(symbol: device.symbol, selected: selected)
                    Text(device.name).lineLimit(1).foregroundStyle(PanelStyle.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: PanelMetrics.deviceSelectionWidth, alignment: .leading)
            .accessibilityLabel(selectionHint ?? L10n.format(
                direction == .input ? "设为默认输入：%@" : "设为默认输出：%@",
                language: language, arguments: [device.name]))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(selectionHint ?? L10n.format(
                selected ? (direction == .input ? "当前默认输入 · %@" : "当前默认输出 · %@")
                         : (direction == .input ? "切换为默认输入 · %@" : "切换为默认输出 · %@"),
                language: language, arguments: [device.uid]))

            switch control {
            case .available(let volume, let mute):
                PanelActionButton(systemName: muteSymbol(mute),
                                  title: L10n.format("%@ 静音", language: language, arguments: [device.name]),
                                  tint: mute.muted == true ? .red : nil,
                                  hoverStyle: .foregroundOnly, action: {
                    if let muted = mute.muted { setMuted(!muted) }
                })
                .disabled(!mute.writable)
                .accessibilityValue(muteDescription(mute))
                .help(L10n.text(mute.writable ? "切换设备静音" : "设备未公开可写的硬件静音控制",
                                language: language))
                if let scalar = volume.scalar {
                    PanelVolumeSlider(value: Binding(get: { Double(scalar) }, set: { setVolume(Float($0)) }),
                                      label: L10n.format(direction == .input ? "%@ 的输入音量" : "%@ 的设备音量",
                                                         language: language, arguments: [device.name]))
                        .frame(minWidth: PanelMetrics.compactSliderMinimumWidth).disabled(!volume.writable)
                        .help(L10n.text(volume.writable
                                        ? (direction == .input ? "输入音量；不采集音频" : "设备音量；不会切换默认输出")
                                        : "设备音量只读", language: language))
                    PanelPercentage(value: scalar)
                } else {
                    Text(L10n.text(direction == .input ? "不支持输入音量" : "不支持系统音量",
                                   language: language)).font(PanelStyle.captionFont)
                        .foregroundStyle(PanelStyle.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                }
            case .failed(let message):
                Label(L10n.text("读取失败", language: language), systemImage: "exclamationmark.circle")
                    .font(PanelStyle.captionFont).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .trailing).help(message)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(height: PanelMetrics.deviceRowHeight)
        .font(PanelStyle.bodyFont)
    }
}

/// 圆底与占位保持 28pt，只缩小内部字形，避免名称、滑杆和行高发生变化。
struct AudioDeviceIcon: View {
    let symbol: String
    let selected: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(selected ? Color.white : PanelStyle.secondary)
            .frame(width: 28, height: 28)
            .background(selected ? PanelStyle.accent : PanelStyle.surface, in: Circle())
    }
}
