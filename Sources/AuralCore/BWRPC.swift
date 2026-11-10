// Derived from HeadBridge (MIT), copyright (c) 2026 HeadBridge contributors.
// Upstream: 5e577cb4a91a515b95596fcc4b362a86ecb639a5
// 许可全文见 ThirdParty/HeadBridge/LICENSE；仅保留本阶段使用的无损控制命令。
import Foundation

struct BWRPCCommand: Hashable, Sendable {
    let namespace: UInt8
    let id: UInt8
    var key: String { String(format: "%02X:%02X", namespace, id) }
}

struct BWRPCMessage: Sendable {
    enum Kind: Sendable { case response, notification }
    let kind: Kind
    let command: BWRPCCommand
    let errorCode: UInt16
    let payload: MessagePackValue?
    var succeeded: Bool { errorCode == 0 }
}

enum BWRPCError: Error, LocalizedError {
    case packetTooShort, requestTooLarge
    case invalidPayloadLength(type: UInt16, expected: String, actual: Int)
    case unsupportedType(UInt16)
    var errorDescription: String? {
        switch self {
        case .packetTooShort: return "耳机 RPC 数据不完整"
        case .invalidPayloadLength(let type, let expected, let actual):
            return String(format: "耳机 RPC 长度不匹配（类型 %04X，期望 %@ 字节，实际 %d 字节）", type, expected, actual)
        case .requestTooLarge: return "耳机 RPC 请求超出单帧大小"
        case .unsupportedType(let value): return String(format: "不支持的耳机 RPC 类型 0x%04X", value)
        }
    }
}

enum BWRPC {
    static let requestUUID = "ada50ce9-67b8-4a97-9d8e-37e1d083156c"
    static let responseUUID = "cb909093-3559-4b0c-9a7f-3f1773122fdc"
    static let notificationUUID = "df55d475-9a32-457a-9e20-38cf14e853fb"

    static func request(_ command: BWRPCCommand, payload: MessagePackValue? = nil) throws -> Data {
        let payloadData = MessagePack.encode(payload)
        let hasPayload = !payloadData.isEmpty
        let packetSize = hasPayload ? payloadData.count + 6 : 4
        guard packetSize <= 255 else { throw BWRPCError.requestTooLarge }
        var data = Data([UInt8(packetSize)])
        data.append(contentsOf: hasPayload ? [0x0B, 0x92] : [0x0B, 0x12])
        data.append(command.id)
        data.append(command.namespace)
        if hasPayload {
            data.append(UInt8(payloadData.count & 0xFF))
            data.append(UInt8((payloadData.count >> 8) & 0xFF))
            data.append(payloadData)
        }
        return data
    }

    static func decode(_ data: Data) throws -> BWRPCMessage {
        let bytes = Array(data)
        guard bytes.count >= 4 else { throw BWRPCError.packetTooShort }
        let type = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let command = BWRPCCommand(namespace: bytes[3], id: bytes[2])
        let kind: BWRPCMessage.Kind
        let errorCode: UInt16
        let headerSize: Int
        let lengthOffset: Int?
        switch type {
        case 0x120C:
            guard bytes.count >= 5 else { throw BWRPCError.packetTooShort }
            // 上游实测用例含 6 字节短响应（LE16 错误码）；协议记录也列出 5 字节形式。
            // 两者按实际帧长度明确区分，不猜偏移，不忽略尾字节。
            switch bytes.count {
            case 5: errorCode = UInt16(bytes[4])
            case 6: errorCode = UInt16(bytes[4]) | UInt16(bytes[5]) << 8
            default: throw BWRPCError.invalidPayloadLength(type: type, expected: "5 或 6", actual: bytes.count)
            }
            kind = .response; headerSize = bytes.count; lengthOffset = nil
        case 0x920C:
            guard bytes.count >= 8 else { throw BWRPCError.packetTooShort }
            kind = .response; errorCode = UInt16(bytes[4]) | UInt16(bytes[5]) << 8
            headerSize = 8; lengthOffset = 6
        case 0x120D:
            kind = .notification; errorCode = 0; headerSize = 4; lengthOffset = nil
        case 0x920D:
            guard bytes.count >= 6 else { throw BWRPCError.packetTooShort }
            kind = .notification; errorCode = 0; headerSize = 6; lengthOffset = 4
        default: throw BWRPCError.unsupportedType(type)
        }
        var payload: MessagePackValue?
        if let offset = lengthOffset {
            let length = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            guard headerSize + length == bytes.count else { throw BWRPCError.invalidPayloadLength(type: type, expected: String(headerSize + length), actual: bytes.count) }
            payload = try MessagePack.decode(Data(bytes[headerSize...]))
        } else {
            guard bytes.count == headerSize else { throw BWRPCError.invalidPayloadLength(type: type, expected: String(headerSize), actual: bytes.count) }
        }
        return BWRPCMessage(kind: kind, command: command, errorCode: errorCode, payload: payload)
    }
}

enum BWRPCatalog {
    static let ancGet = BWRPCCommand(namespace: 0x03, id: 0x01)
    static let ancSet = BWRPCCommand(namespace: 0x03, id: 0x02)
    static let addressGet = BWRPCCommand(namespace: 0x08, id: 0x02)
    static let batteryGet = BWRPCCommand(namespace: 0x08, id: 0x0C)
    static let primaryReads = [batteryGet, ancGet]
}
