// Derived from HeadBridge (MIT), Copyright (c) 2026 HeadBridge contributors.
// Upstream: 5e577cb4a91a515b95596fcc4b362a86ecb639a5
// 完整许可见 ThirdParty/HeadBridge/LICENSE；Aural 仅接入已确认的电量和噪声控制。
import Foundation

/// Command ids observed on OPPO/OnePlus/realme earbuds that expose the
/// `0000079A-D102-11E1-9B23-00025B00A5A5` RFCOMM service.
///
/// The wire facts here were verified against an OPPO Enco Air5s
/// (product id `0x06C810`) on 2026-10-24: battery, firmware and the
/// off/noise-cancellation/ambient transitions all round-trip on hardware.
enum OppoCommand: UInt16 {
    case productID = 0x0103
    case firmware = 0x0105
    case battery = 0x0106
    case wearing = 0x0109
    case noiseControl = 0x010C
    case setNoiseControl = 0x0404
    case event = 0x0204
    case gestures = 0x0108
    case features = 0x010D
    case equalizer = 0x010F
    case dualDevices = 0x0112
    case codec = 0x0114
    case customEqualizer = 0x0122
    case codecList = 0x0123
    case spatialType = 0x012A
    case gameSound = 0x012B
    case alertVolume = 0x0130
    case preferredDevice = 0x0132
    case setFeature = 0x0403
    case findEarbuds = 0x0400
    case setGestures = 0x0401
    case selectEqualizer = 0x0406
    case writeEqualizer = 0x0418
    case setCodec = 0x041A
    case setSpatialType = 0x0422
    case setGameSound = 0x0423
    case setAlertVolume = 0x0427
    case dualDeviceAction = 0x0429
}

struct OppoMessage: Equatable {
    let command: UInt16
    let sequence: UInt8
    let payload: [UInt8]
}

enum OppoWire {
    /// `AA <LEB128 total length> 00 00 <cmd LE> <seq> <payload length LE> <payload>`.
    ///
    /// The length counts every byte after the length field, including the two
    /// reserved zero bytes, so an empty payload still produces a length of 7.
    static func encode(command: UInt16, sequence: UInt8, payload: [UInt8]) -> Data {
        let bodyLength = 7 + payload.count
        var bytes: [UInt8] = [0xAA]
        bytes.append(contentsOf: encodeLEB128(bodyLength))
        bytes.append(contentsOf: [0x00, 0x00])
        bytes.append(UInt8(command & 0xFF))
        bytes.append(UInt8(command >> 8))
        bytes.append(sequence)
        bytes.append(UInt8(payload.count & 0xFF))
        bytes.append(UInt8((payload.count >> 8) & 0xFF))
        bytes.append(contentsOf: payload)
        return Data(bytes)
    }

    /// Commands that take a device address write the six bytes in the reverse
    /// order of the human-readable list entry.
    static func macBytes(from address: String) -> [UInt8]? {
        let parts = address.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard parts.count == 6 else { return nil }
        return parts.reversed()
    }

    static func encodeLEB128(_ value: Int) -> [UInt8] {
        precondition(value >= 0)
        var remaining = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 {
                byte |= 0x80
            }
            bytes.append(byte)
        } while remaining != 0
        return bytes
    }
}

/// Bounded frame reassembler. Notifications may be split across RFCOMM reads
/// and may contain more than one frame; malformed length prefixes are dropped
/// instead of allowing the buffer to grow without limit.
struct OppoFrameParser {
    private static let maximumFrameLength = 2_048
    private static let maximumBufferLength = 4_096
    private var buffer: [UInt8] = []

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    mutating func append(_ data: Data) -> [OppoMessage] {
        buffer.append(contentsOf: data)
        var messages: [OppoMessage] = []

        while let preamble = buffer.firstIndex(of: 0xAA) {
            if preamble > 0 {
                buffer.removeFirst(preamble)
            }
            guard buffer.count >= 3 else { break }

            var length = 0
            var shift = 0
            var cursor = 1
            var lengthComplete = false
            while cursor < buffer.count {
                let byte = buffer[cursor]
                length |= Int(byte & 0x7F) << shift
                cursor += 1
                if byte & 0x80 == 0 {
                    lengthComplete = true
                    break
                }
                shift += 7
                if shift > 21 {
                    break
                }
            }

            guard lengthComplete else {
                // A frame longer than the supported prefix is not recoverable.
                if buffer.count > 4 {
                    buffer.removeFirst()
                    continue
                }
                break
            }

            guard length >= 7, length <= Self.maximumFrameLength else {
                buffer.removeFirst()
                continue
            }

            let total = cursor + length
            guard buffer.count >= total else { break }

            // The two reserved bytes are always zero for a whole message. If
            // they are not, this is a stray 0xAA in another frame: resync.
            guard buffer[cursor] == 0x00, buffer[cursor + 1] == 0x00 else {
                buffer.removeFirst()
                continue
            }

            let frame = Array(buffer[0..<total])
            buffer.removeFirst(total)
            if let message = Self.parse(frame) {
                messages.append(message)
            }
        }

        if buffer.count > Self.maximumBufferLength {
            buffer.removeAll(keepingCapacity: true)
        }
        return messages
    }

    static func parse(_ frame: [UInt8]) -> OppoMessage? {
        guard frame.count >= 9, frame[0] == 0xAA else { return nil }

        var cursor = 1
        var shift = 0
        var length = 0
        var lengthComplete = false
        while cursor < frame.count {
            let byte = frame[cursor]
            length |= Int(byte & 0x7F) << shift
            cursor += 1
            if byte & 0x80 == 0 {
                lengthComplete = true
                break
            }
            shift += 7
            if shift > 21 { return nil }
        }
        guard lengthComplete, length >= 7, length <= maximumFrameLength else { return nil }
        guard cursor + length <= frame.count else { return nil }

        let command = UInt16(frame[cursor + 2]) | (UInt16(frame[cursor + 3]) << 8)
        let sequence = frame[cursor + 4]
        let payloadLength = Int(frame[cursor + 5]) | (Int(frame[cursor + 6]) << 8)
        guard payloadLength <= maximumFrameLength else { return nil }
        let payloadStart = cursor + 7
        guard payloadStart + payloadLength <= frame.count else { return nil }

        return OppoMessage(
            command: command,
            sequence: sequence,
            payload: Array(frame[payloadStart..<(payloadStart + payloadLength)])
        )
    }
}

struct OppoBattery: Equatable {
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var isCharging = false

    /// 仅用于需要单值摘要的兼容计算；界面和菜单栏会保留左右耳及充电盒的原始部件值。
    var lowestEarbudLevel: Int? {
        switch (left, right) {
        case let (left?, right?): min(left, right)
        case let (left?, nil): left
        case let (nil, right?): right
        case (nil, nil): caseLevel
        }
    }

    var batteryReading: HeadphoneBatteryReading {
        HeadphoneBatteryReading(left: left, right: right, caseLevel: caseLevel, isCharging: isCharging)
    }
}

enum OppoBatteryCodec {
    /// Payload begins with the status byte, then `<count>` and `(id, level)`
    /// pairs. Id 1 is the left bud, 2 the right bud, 3 the charging case.
    static func decode(_ payload: [UInt8]) -> OppoBattery? {
        guard payload.count >= 2, payload[0] == 0x00 else { return nil }
        let count = Int(payload[1])
        // count 声明的记录必须完整到达；不能在截断处 break 后发布半份读数。
        guard count > 0, count <= 8, payload.count >= 2 + count * 2 else { return nil }

        var reading = OppoBattery()
        var seen: Set<UInt8> = []
        var cursor = 2
        for _ in 0..<count {
            let identifier = payload[cursor]
            let rawLevel = payload[cursor + 1]
            cursor += 2
            // 不认识的扩展部件不参与电量或充电判断；已知部件重复或越界则明确拒绝。
            guard (1...3).contains(identifier) else { continue }
            let level = Int(rawLevel & 0x7F)
            guard seen.insert(identifier).inserted, level <= 100 else { return nil }
            if rawLevel & 0x80 != 0 {
                reading.isCharging = true
            }

            switch identifier {
            case 1: reading.left = level
            case 2: reading.right = level
            case 3: reading.caseLevel = level
            default: break
            }
        }

        guard reading.left != nil || reading.right != nil || reading.caseLevel != nil else {
            return nil
        }
        return reading
    }
}

enum OppoNoiseLevel: Int, CaseIterable, Identifiable {
    case light = 0x40
    case deep = 0x10
    case smart = 0x80

    var id: Int { rawValue }
}

enum OppoNoiseCodec {
    /// Reply to `0x010C 01 01`: `00 01 01 <mode LE>`.
    static func decodeReport(_ payload: [UInt8]) -> NoiseMode? {
        reportRawValue(payload).flatMap(mode(forRawValue:))
    }

    static func reportRawValue(_ payload: [UInt8]) -> UInt32? {
        guard payload.count >= 5, payload[0] == 0x00, payload[1] == 0x01, payload[2] == 0x01
        else { return nil }
        return littleEndianValue(payload, from: 3)
    }

    static func level(forRawValue raw: UInt32) -> OppoNoiseLevel? {
        OppoNoiseLevel(rawValue: Int(raw))
    }

    /// `0x010C 02 01` → `00 02 01 <mask LE>`; modes the touch-and-hold cycles.
    static func decodeHoldCycle(_ payload: [UInt8]) -> UInt16? {
        guard payload.count >= 5, payload[0] == 0x00, payload[1] == 0x02, payload[2] == 0x01
        else { return nil }
        return UInt16(payload[3]) | (UInt16(payload[4]) << 8)
    }

    static func encodeHoldCycle(_ mask: UInt16, sequence: UInt8) -> Data {
        OppoWire.encode(
            command: OppoCommand.setNoiseControl.rawValue,
            sequence: sequence,
            payload: [0x02, 0x01, UInt8(mask & 0xFF)]
        )
    }

    /// `0x010C 04 01` → `00 04 01 <mask LE>`; Smart's chosen level.
    static func decodeSmartLevel(_ payload: [UInt8]) -> OppoNoiseLevel? {
        guard payload.count >= 5, payload[0] == 0x00, payload[1] == 0x04, payload[2] == 0x01
        else { return nil }
        return littleEndianValue(payload, from: 3).flatMap(level(forRawValue:))
    }

    /// Unsolicited push `02 04` event code `03`: `01 01 <mode LE>`.
    static func decodeEvent(_ payload: [UInt8]) -> NoiseMode? {
        guard payload.count >= 4, payload[0] == 0x01, payload[1] == 0x01 else { return nil }
        return littleEndianValue(payload, from: 2).flatMap(mode(forRawValue:))
    }

    /// The mode is 1-4 bytes little-endian in replies and pushes.
    private static func littleEndianValue(_ payload: [UInt8], from index: Int) -> UInt32? {
        let available = min(4, payload.count - index)
        guard available > 0 else { return nil }
        var value: UInt32 = 0
        for offset in 0..<available {
            value |= UInt32(payload[index + offset]) << (8 * offset)
        }
        return value
    }

    /// Reports use a mask that is not the same table as the write bits. The
    /// four ANC levels all belong to the single noise-cancellation control
    /// HeadBridge exposes.
    static func mode(forRawValue raw: UInt32) -> NoiseMode? {
        switch raw {
        case 0x0008:
            .off
        case 0x0002, 0x0010, 0x0020, 0x0040, 0x0080:
            .cancellation
        case 0x0100, 0x0200:
            .transparency
        default:
            nil
        }
    }

    static func encodeSetLevel(_ level: OppoNoiseLevel, sequence: UInt8) -> Data {
        OppoWire.encode(
            command: OppoCommand.setNoiseControl.rawValue,
            sequence: sequence,
            payload: [0x01, 0x01, UInt8(level.rawValue)]
        )
    }

    /// `0x0404 01 01 <mask LE>`; the mask is one bit for the model's slot.
    static func encodeSet(mode: NoiseMode, profile: OppoModelProfile, sequence: UInt8) -> Data? {
        guard let bit = profile.noiseBits[mode] else { return nil }
        let byteCount = Int(bit) / 8 + 1
        var mask = [UInt8](repeating: 0, count: byteCount)
        mask[Int(bit) / 8] = 1 << (bit % 8)
        return OppoWire.encode(
            command: OppoCommand.setNoiseControl.rawValue,
            sequence: sequence,
            payload: [0x01, 0x01] + mask
        )
    }
}

/// Model-specific write slots. Only models whose table has been verified on
/// hardware belong here: an incorrect slot changes the wrong noise mode.
struct OppoModelProfile {
    let productID: UInt32
    let displayName: String
    let noiseBits: [NoiseMode: UInt8]
    let featureQuery: [UInt8]
    let builtInEQPresets: [OppoBuiltInEQPreset]

    static let knownProfiles: [OppoModelProfile] = [
        OppoModelProfile(
            productID: 0x06C810,
            displayName: "OPPO Enco Air5s",
            // Verified on hardware: bit 0 = off, 1 = ANC, 2 = ambient.
            noiseBits: [.off: 0, .cancellation: 1, .transparency: 2],
            // Ids the firmware answered on 2026-10-24.
            featureQuery: [0x05, 0x04, 0x11, 0x18, 0x06, 0x1B, 0x1D, 0x1E, 0x27, 0x28, 0x37],
            builtInEQPresets: [
                OppoBuiltInEQPreset(id: 0, name: "Ultimate"),
                OppoBuiltInEQPreset(id: 1, name: "Thundering Bass"),
                OppoBuiltInEQPreset(id: 2, name: "Pure Vocals"),
            ]
        )
    ]

    static func profile(for productID: UInt32) -> OppoModelProfile? {
        knownProfiles.first { $0.productID == productID }
    }

    static func productID(from payload: [UInt8]) -> UInt32? {
        guard payload.count >= 4, payload[0] == 0x00 else { return nil }
        return UInt32(payload[1]) | (UInt32(payload[2]) << 8) | (UInt32(payload[3]) << 16)
    }
}

enum OppoPushEvent: Equatable {
    case battery(OppoBattery)
    case noiseMode(NoiseMode)
}

enum OppoEventCodec {
    /// Command `0x0204` is a multiplexed event channel; payload byte 0 selects
    /// the event. Codes 2 (wearing), 6 (multipoint list) and others are ignored.
    static func decode(_ message: OppoMessage) -> OppoPushEvent? {
        guard message.command == OppoCommand.event.rawValue, let code = message.payload.first else {
            return nil
        }
        let body = Array(message.payload.dropFirst())
        switch code {
        case 0x01:
            return OppoBatteryCodec.decode(body).map(OppoPushEvent.battery)
        case 0x03:
            return OppoNoiseCodec.decodeEvent(body).map(OppoPushEvent.noiseMode)
        default:
            return nil
        }
    }
}

// 保留已知型号表所用的上游结构，不接入其高级设置、响铃或佩戴检测。
struct OppoBuiltInEQPreset: Identifiable, Equatable {
    let id: UInt8
    let name: String
}
