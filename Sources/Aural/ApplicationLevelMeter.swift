import SwiftUI

/// 更宽、更矮的峰值表固定放在应用图标左侧，不占第二行，也不跟随滑杆百分比假跳动。
struct ApplicationLevelMeter: View {
    let level: Float?
    let applicationName: String
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(spacing: 1) {
            ForEach(0..<10) { index in
                let threshold = Float(10 - index) / 10
                let active = level.map { $0 >= threshold } == true
                Rectangle()
                    .fill(active ? color(index: index) : PanelStyle.line)
                    .frame(height: 1)
            }
        }
        .frame(width: 10, height: 20)
        .opacity(level == nil ? 0.45 : 1)
        .help(L10n.text(level == nil ? "电平尚未读取" : "实时音频电平", language: language))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.format("%@ 的实时音频电平", language: language,
                                        arguments: [applicationName]))
        .accessibilityValue(accessibleValue)
    }

    private func color(index: Int) -> Color {
        if index == 0 { return .red }
        if index <= 2 { return .yellow }
        return Color(red: 0.28, green: 0.70, blue: 0.40)
    }

    private var accessibleValue: String {
        guard let level else { return L10n.text("尚未读取", language: language) }
        if level == 0 { return L10n.text("低于负 60 dBFS", language: language) }
        return "\(Int(level * 60 - 60)) dBFS"
    }
}
