import Foundation

/// Core Audio 使用经典蓝牙地址标识耳机，CoreBluetooth UUID 不是永久硬件地址。
/// 所有正常连接都走同一个 RPC 地址核验，不在旧 UUID 失败后改用另一条后备协议。
public enum HeadphonePhysicalIdentity {
    /// Px7 S3 的双模硬件会公开经典蓝牙音频地址和独立 BLE 控制地址。
    /// 两者共享 B&W Group 的 OUI，但后三个字节不同，不能按完整 MAC 直接比较。
    private static let bowersWilkinsVendorPrefix = "EC66D1"

    public static func canonicalAddress(_ value: String) -> String? {
        let upper = value.uppercased()
        guard upper.unicodeScalars.allSatisfy({
            (48...57).contains($0.value) || (65...70).contains($0.value) || $0 == ":" || $0 == "-"
        }) else { return nil }
        let compact = upper.filter { $0 != ":" && $0 != "-" }
        guard compact.count == 12 else { return nil }
        return compact
    }

    public static func addressInOutputUID(_ uid: String) -> String? {
        guard uid.hasSuffix(":output") else { return nil }
        return canonicalAddress(String(uid.dropLast(7)))
    }

    public static func matches(reported: String, outputUID: String) -> Bool {
        guard let actual = canonicalAddress(reported), let expected = addressInOutputUID(outputUID) else { return false }
        return actual == expected
    }

    /// B&W 控制通道允许使用同一厂商前缀的另一颗 BLE 电台，
    /// 但必须同时满足系统输出名与控制广播名一致，不能只凭厂商前缀放行。
    public static func matchesBowersWilkinsControl(reported: String,
                                                   outputUID: String,
                                                   advertisedName: String?,
                                                   outputName: String?) -> Bool {
        guard let actual = canonicalAddress(reported), let expected = addressInOutputUID(outputUID) else {
            return false
        }
        if actual == expected { return true }
        guard actual.hasPrefix(bowersWilkinsVendorPrefix),
              expected.hasPrefix(bowersWilkinsVendorPrefix),
              let advertisedName, let outputName else {
            return false
        }
        return HeadphoneIdentity.normalizedName(advertisedName) == HeadphoneIdentity.normalizedName(outputName)
    }
}
