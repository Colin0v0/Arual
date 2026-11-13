import Foundation

/// 依据 ZenControl PROTOCOL.md 的公开协议事实独立实现；不包含其源文件。
/// 只接入 ACCENTUM Wireless (ACAEBT)，不向 MOMENTUM 或 Plus 套用切换命令。
struct SennheiserGAIAFrame: Equatable {
    let vendor: UInt16
    let command: UInt16
    let payload: Data
}

enum SennheiserGAIAProtocol {
    static let vendor: UInt16 = 0x0495
    static let serviceUUID = "a2129ff3-081b-4c45-8afe-469d9c4842ec"
    static let modelGet: UInt16 = 0x1206
    static let batteryGet: UInt16 = 0x0603
    static let ancGet: UInt16 = 0x1A05
    static let transparencyGet: UInt16 = 0x1805
    static let ancSet: UInt16 = 0x1A04
    static let transparencySet: UInt16 = 0x1804
    static let registerNotification: UInt16 = 0x0007

    static func request(_ command: UInt16, payload: [UInt8] = []) -> Data {
        precondition(payload.count <= 1024)
        let size = UInt16(payload.count)
        return Data([0xFF, 0x03, UInt8(size >> 8), UInt8(size & 0xFF),
                     0x04, 0x95, UInt8(command >> 8), UInt8(command & 0xFF)] + payload)
    }

    static func modelID(_ payload: Data) -> String? {
        let bytes = [UInt8](payload)
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        guard !bytes.isEmpty, bytes[end...].allSatisfy({ $0 == 0 }),
              bytes[..<end].allSatisfy({ (0x20...0x7E).contains($0) }),
              let value = String(bytes: bytes[..<end], encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    static func isAccentumWireless(_ model: String) -> Bool {
        guard model == "ACAEBT" || model.hasPrefix("ACAEBT ") else { return false }
        let normalized = model.lowercased()
        // 型号串可以带颜色后缀，但不能把 Plus 或真无线款误认成基础头戴款。
        return !normalized.contains("plus")
            && !normalized.contains("true wireless")
            && !normalized.hasSuffix(" tw")
    }

    static func battery(_ payload: Data) -> Int? {
        guard payload.count == 1, let value = payload.first, value <= 100 else { return nil }
        return Int(value)
    }

    static func toggle(_ payload: Data) -> Bool? {
        guard payload.count == 1, let value = payload.first, value <= 1 else { return nil }
        return value == 1
    }

    /// 两项开关均回读后才能确定模式；不把未读取当成 false。
    static func noiseMode(anc: Bool?, transparency: Bool?) -> NoiseMode? {
        guard let anc, let transparency else { return nil }
        if transparency { return .transparency }
        return anc ? .cancellation : .off
    }

    /// 先关互斥项，再开目标；未知模式没有映射，不能用 Off 代替。
    static func noiseWrites(_ mode: NoiseMode) -> [(UInt16, UInt8)]? {
        switch mode {
        case .off: return [(transparencySet, 0), (ancSet, 0)]
        case .cancellation: return [(transparencySet, 0), (ancSet, 1)]
        case .transparency: return [(ancSet, 0), (transparencySet, 1)]
        case .windReduction, .adaptive: return nil
        }
    }
}

/// RFCOMM 半包/粘包按长度解析。坏帧直接失败，不扫描字节猜边界。
struct SennheiserGAIADecoder {
    private var pending = Data()
    mutating func reset() { pending.removeAll(keepingCapacity: true) }
    mutating func append(_ data: Data) throws -> [SennheiserGAIAFrame] {
        pending.append(data)
        var frames: [SennheiserGAIAFrame] = []
        while pending.count >= 8 {
            let start = pending.startIndex
            let length = Int(pending[start + 2]) << 8 | Int(pending[start + 3])
            guard pending[start] == 0xFF, pending[start + 1] == 0x03, length <= 1024 else {
                reset()
                throw AudioFailure("森海塞尔 GAIA 回包格式无效")
            }
            guard pending.count >= 8 + length else { break }
            frames.append(SennheiserGAIAFrame(
                vendor: UInt16(pending[start + 4]) << 8 | UInt16(pending[start + 5]),
                command: UInt16(pending[start + 6]) << 8 | UInt16(pending[start + 7]),
                payload: pending.subdata(in: (start + 8)..<(start + 8 + length))))
            pending.removeFirst(8 + length)
        }
        return frames
    }
}
