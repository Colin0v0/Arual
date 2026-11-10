import Foundation

/// Core Audio 使用经典蓝牙地址标识耳机，CoreBluetooth UUID 不是永久硬件地址。
/// 所有正常连接都走同一个 RPC 地址核验，不在旧 UUID 失败后改用另一条后备协议。
public enum HeadphonePhysicalIdentity {
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
}
