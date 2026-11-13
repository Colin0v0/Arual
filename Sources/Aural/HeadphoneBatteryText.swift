import Foundation
import AuralCore

/// 耳机面板、菜单栏和辅助功能共用同一份电量格式化规则。
enum HeadphoneBatteryText {
    /// 面板与悬停提示展示协议返回的全部部件，缺失部件不补零。
    static func detail(_ reading: HeadphoneBatteryReading, language: AppLanguage) -> String {
        var parts: [String] = []
        if let single = valid(reading.single) {
            parts.append("\(single)%")
        }
        if let left = valid(reading.left) {
            parts.append(L10n.format("左 %d%%", language: language, arguments: [left]))
        }
        if let right = valid(reading.right) {
            parts.append(L10n.format("右 %d%%", language: language, arguments: [right]))
        }
        if let caseLevel = valid(reading.caseLevel) {
            parts.append(L10n.format("盒 %d%%", language: language, arguments: [caseLevel]))
        }
        return parts.joined(separator: " · ")
    }

    /// 菜单栏保持紧凑：只在左右耳电平不同的时候使用 L/R 缩写。
    static func compact(_ reading: HeadphoneBatteryReading) -> String {
        if let single = valid(reading.single) {
            return "\(single)%"
        }
        let left = valid(reading.left)
        let right = valid(reading.right)
        switch (left, right) {
        case let (left?, right?):
            return left == right ? "\(left)%" : "L\(left) / R\(right)"
        case let (left?, nil):
            return "L\(left)"
        case let (nil, right?):
            return "R\(right)"
        case (nil, nil):
            // 仅充电盒电量时没有可放进菜单栏的耳机数字；提示中仍完整展示。
            return ""
        }
    }

    static func accessibility(_ reading: HeadphoneBatteryReading, language: AppLanguage) -> String? {
        let detail = detail(reading, language: language)
        guard !detail.isEmpty else { return nil }
        return L10n.format("耳机电量：%@", language: language, arguments: [detail])
    }

    private static func valid(_ value: Int?) -> Int? {
        guard let value, (0...100).contains(value) else { return nil }
        return value
    }
}
