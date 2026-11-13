// Bose BMAP protocol facts are based on bosectl (MIT).
// Aural implements the framing, state machine and Core Audio lifecycle independently.
import Foundation

/// BMAP 帧由厂商私有 RFCOMM 通道直接承载：
/// `[functionBlock, function, flags, payloadLength, payload...]`。
enum BoseBMAPOperator: UInt8 {
    case set = 0
    case get = 1
    case setGet = 2
    case status = 3
    case error = 4
    case start = 5
    case result = 6
    case processing = 7

    /// 只有这些操作符可能由耳机发回；GET/SETGET/START 是主机请求方向。
    var isDeviceResponse: Bool {
        switch self {
        case .status, .error, .result, .processing: return true
        case .set, .get, .setGet, .start: return false
        }
    }
}

struct BoseBMAPFrame: Equatable {
    let functionBlock: UInt8
    let function: UInt8
    let flags: UInt8
    let payload: Data

    var operation: BoseBMAPOperator? {
        BoseBMAPOperator(rawValue: flags & 0x0F)
    }
}

/// 产品 ID 是驱动契约，不能从用户可修改的蓝牙名称推断电量形状。
/// 两款 Ultra 二代均有 bosectl 真机资料，但头戴和入耳的电量载荷不同。
enum BoseControlEndpoint: Equatable {
    case ultraChannel2
    /// prince / duran 的厂商控制在已确认的 SPP 记录上；通道号以 SDP 为准，不轮询猜测。
    case serialPortService
}

enum BoseBMAPModel: UInt16, CaseIterable {
    case quietComfortUltraHeadphones2 = 0x4082
    case quietComfortUltraEarbuds2 = 0x4062
    case quietComfortHeadphones = 0x4075
    case quietComfort45 = 0x4039

    var catalogID: String {
        switch self {
        case .quietComfortUltraHeadphones2: return "bose-quietcomfort-ultra-headphones-2"
        case .quietComfortUltraEarbuds2: return "bose-quietcomfort-ultra-earbuds-2"
        case .quietComfortHeadphones: return "bose-quietcomfort-headphones"
        case .quietComfort45: return "bose-quietcomfort-45"
        }
    }

    var batteryCapability: HeadphoneBatteryCapability {
        switch self {
        case .quietComfortUltraHeadphones2, .quietComfortHeadphones, .quietComfort45: return .single
        case .quietComfortUltraEarbuds2: return .earbudsWithCase
        }
    }

    var endpoint: BoseControlEndpoint {
        switch self {
        case .quietComfortUltraHeadphones2, .quietComfortUltraEarbuds2: return .ultraChannel2
        case .quietComfortHeadphones, .quietComfort45: return .serialPortService
        }
    }

    var requiresInitialization: Bool { self == .quietComfort45 }
    var acceptsProcessingAcknowledgement: Bool {
        self == .quietComfortHeadphones || self == .quietComfort45
    }
    var compatibility: HeadphoneCompatibilityStatus {
        // 上游 QC45 的 README 与型号实现验证注释不一致，因此不宣称真机已验证。
        self == .quietComfort45 ? .experimental : .upstreamVerified
    }

    /// 当前仅接入两种基本预设 Quiet=0、Aware=1；其他预设不映射成 Off。
    var noiseModes: [NoiseMode] { [.cancellation, .transparency] }
}

/// 只解析 Aural 明确接入并通过产品 ID 核验的 Bose BMAP 型号。
enum BoseBMAPProtocol {
    static let functionBlockInfo: UInt8 = 0x00
    static let productIDVariants: UInt8 = 0x03
    static let batteryBlock: UInt8 = 0x02
    static let batteryLevel: UInt8 = 0x02
    static let audioModesBlock: UInt8 = 0x1F
    static let currentMode: UInt8 = 0x03

    static let quietComfortUltraHeadphones2Mode: UInt8 = 0
    static let awareMode: UInt8 = 1

    static func initializeLegacyProduct() -> Data {
        packet(functionBlock: 0, function: 1, operation: .get)
    }

    static func queryProductIdentity() -> Data {
        packet(functionBlock: functionBlockInfo, function: productIDVariants, operation: .get)
    }

    static func queryBattery() -> Data {
        packet(functionBlock: batteryBlock, function: batteryLevel, operation: .get)
    }

    static func queryCurrentMode() -> Data {
        packet(functionBlock: audioModesBlock, function: currentMode, operation: .get)
    }

    static func switchMode(index: UInt8) -> Data {
        // START 是 bosectl 在 wolverine 上确认的无认证模式切换操作。
        packet(functionBlock: audioModesBlock, function: currentMode,
               operation: .start, payload: [index, 0])
    }

    static func parseProductID(_ frame: BoseBMAPFrame) -> UInt16? {
        guard frame.operation == .status,
              frame.functionBlock == functionBlockInfo,
              frame.function == productIDVariants,
              frame.payload.count >= 3 else { return nil }
        let bytes = [UInt8](frame.payload)
        return (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }

    /// 按已经核验的产品解释电量，不能在解析失败后试另一种布局。
    static func parseBattery(_ frame: BoseBMAPFrame, model: BoseBMAPModel) -> HeadphoneBatteryReading? {
        guard isStatus(frame, block: batteryBlock, function: batteryLevel) else { return nil }
        let bytes = [UInt8](frame.payload)
        switch model {
        case .quietComfortUltraHeadphones2, .quietComfortHeadphones, .quietComfort45:
            // wolverine / prince / duran 的整机电量为 `[percentage, reserved, reserved, 0]`。
            guard bytes.count == 4, bytes[0] <= 100, bytes[3] == 0 else { return nil }
            return HeadphoneBatteryReading(single: Int(bytes[0]))
        case .quietComfortUltraEarbuds2:
            // edith 按四字节记录上报：1=右耳、2=左耳、3=盒、4=双耳合并。
            // 各部件可能缺失或为 0xFF，不从合并电量推算单耳，也不推断充电状态。
            guard !bytes.isEmpty, bytes.count % 4 == 0 else { return nil }
            var reading = HeadphoneBatteryReading()
            var seen: Set<UInt8> = []
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let component = bytes[offset + 3]
                guard seen.insert(component).inserted else { return nil }
                guard (1...3).contains(component) else { continue }
                let level = bytes[offset]
                if level == 0xFF { continue }
                guard level <= 100 else { return nil }
                switch component {
                case 1: reading.right = Int(level)
                case 2: reading.left = Int(level)
                case 3: reading.caseLevel = Int(level)
                default: break
                }
            }
            // 完整的未知值响应也要返回空读数，以清除之前已不再有效的部件。
            return reading
        }
    }

    /// 当前模式载荷的第一个字节是 AudioModes 索引。
    /// 当前接入的 wolverine / edith 产品中 0 为 Quiet、1 为 Aware。
    static func parseNoiseMode(_ frame: BoseBMAPFrame) -> NoiseMode? {
        guard frame.operation == .status,
              frame.functionBlock == audioModesBlock,
              frame.function == currentMode,
              let index = frame.payload.first else { return nil }
        switch index {
        case quietComfortUltraHeadphones2Mode: return .cancellation
        case awareMode: return .transparency
        default: return nil
        }
    }

    static func modeIndex(for noiseMode: NoiseMode) -> UInt8? {
        switch noiseMode {
        case .cancellation: return quietComfortUltraHeadphones2Mode
        case .transparency: return awareMode
        case .off, .windReduction, .adaptive: return nil
        }
    }

    static func isStatus(_ frame: BoseBMAPFrame, block: UInt8, function: UInt8) -> Bool {
        frame.operation == .status && frame.functionBlock == block && frame.function == function
    }

    static func isCompletedModeSwitch(_ frame: BoseBMAPFrame) -> Bool {
        frame.operation == .result
            && frame.functionBlock == audioModesBlock
            && frame.function == currentMode
    }

    static func isModeSwitchAcknowledgement(_ frame: BoseBMAPFrame, model: BoseBMAPModel) -> Bool {
        guard frame.functionBlock == audioModesBlock, frame.function == currentMode else { return false }
        return frame.operation == .result
            || (model.acceptsProcessingAcknowledgement && frame.operation == .processing)
    }

    private static func packet(functionBlock: UInt8, function: UInt8,
                               operation: BoseBMAPOperator,
                               payload: [UInt8] = []) -> Data {
        precondition(payload.count <= 255)
        return Data([functionBlock, function, operation.rawValue, UInt8(payload.count)] + payload)
    }
}

/// RFCOMM 数据可能被拆成任意小段，也可能一次返回多个 BMAP 帧。
struct BoseBMAPDecoder {
    private var pending = Data()

    mutating func append(_ data: Data) throws -> [BoseBMAPFrame] {
        pending.append(data)
        var frames: [BoseBMAPFrame] = []

        while pending.count >= 4 {
            let payloadLength = Int(pending[pending.startIndex + 3])
            guard let operation = BoseBMAPOperator(rawValue: pending[pending.startIndex + 2] & 0x0F),
                  operation.isDeviceResponse else {
                // BMAP 没有同步标记或校验和，不能通过逐字节猜测帧头恢复，
                // 否则坏帧载荷可能被拼成假的身份或模式回包。明确中止本次控制连接。
                reset()
                throw AudioFailure("Bose BMAP 回包包含无效操作符")
            }

            let frameLength = 4 + payloadLength
            guard pending.count >= frameLength else { break }
            let start = pending.startIndex
            let payload = pending.subdata(in: (start + 4)..<(start + frameLength))
            frames.append(BoseBMAPFrame(
                functionBlock: pending[start],
                function: pending[start + 1],
                flags: pending[start + 2],
                payload: payload
            ))
            pending.removeFirst(frameLength)
        }
        return frames
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }
}
