import SwiftUI
import AuralCore

/// 麦克风沿用输出行的布局；只向输入接口传递动作，不提供未经实现的按 APP 麦克风混音。
struct InputDevicesSection: View {
    let audio: SystemInputSnapshot
    let select: (UInt32) -> Void
    let setVolume: (Float, UInt32) -> Void
    let setMuted: (Bool, UInt32) -> Void
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(spacing: 0) {
            if audio.inputs.isEmpty {
                Label(L10n.text("暂无可用麦克风", language: language), systemImage: "mic.slash")
                    .foregroundStyle(PanelStyle.secondary).frame(maxWidth: .infinity).padding(.vertical, 20)
            }
            ForEach(audio.inputs) { input in
                if let control = audio.controls[input.id] {
                    AudioDeviceRow(device: input, control: control, selected: input.id == audio.selectedID,
                                   select: { select(input.id) }, setVolume: { setVolume($0, input.id) },
                                   setMuted: { setMuted($0, input.id) })
                } else {
                    PanelError(text: L10n.format("%@ 尚未读取输入控制状态", language: language,
                                                 arguments: [input.name])).padding(12)
                }
            }
        }
    }
}

