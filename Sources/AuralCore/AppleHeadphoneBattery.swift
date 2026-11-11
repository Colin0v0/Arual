import Foundation

/// 系统最近上报的各部件电量；缺失值保持未知，充电盒不参与耳机电量汇总。
public struct AppleHeadphoneBattery: Equatable, Sendable {
    public let left: Int?
    public let right: Int?
    public let caseLevel: Int?
    public init(left: Int? = nil, right: Int? = nil, caseLevel: Int? = nil) {
        self.left = left; self.right = right; self.caseLevel = caseLevel
    }
    public var earbudLevel: Int? { [left, right].compactMap { $0 }.min() }
}

/// 唯一电量数据源是系统蓝牙报告；按真实地址匹配，不按可修改的设备名配对。
@MainActor
final class AppleHeadphoneBatteryStore {
    static let shared = AppleHeadphoneBatteryStore()
    private var readings: [String: AppleHeadphoneBattery] = [:]
    private var failure: String?
    private var lastAttempt: Date?
    private var task: Task<Void, Never>?

    func battery(for output: AudioOutput) throws -> AppleHeadphoneBattery? {
        let refreshDue: Bool
        if let lastAttempt { refreshDue = Date().timeIntervalSince(lastAttempt) >= 60 }
        else { refreshDue = true }
        if task == nil && refreshDue {
            lastAttempt = Date()
            task = Task { [weak self] in
                do {
                    let values = try await Task.detached(priority: .utility) {
                        try Self.readSystemReport()
                    }.value
                    self?.readings = values
                    self?.failure = nil
                } catch {
                    self?.readings = [:]
                    self?.failure = error.localizedDescription
                }
                self?.task = nil
            }
        }
        if let failure { throw AudioFailure("读取 Apple 耳机电量失败：\(failure)") }
        guard let address = HeadphonePhysicalIdentity.addressInOutputUID(output.uid) else { return nil }
        return readings[address]
    }

    nonisolated private static func readSystemReport() throws -> [String: AppleHeadphoneBattery] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-timeout", "10"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AudioFailure("系统蓝牙报告退出码 \(process.terminationStatus)")
        }
        return try parse(data)
    }

    nonisolated static func parse(_ data: Data) throws -> [String: AppleHeadphoneBattery] {
        struct Report: Decodable {
            let SPBluetoothDataType: [Adapter]
            struct Adapter: Decodable { let device_connected: [[String: Device]]? }
            struct Device: Decodable {
                let device_address: String?
                let device_batteryLevelLeft: String?
                let device_batteryLevelRight: String?
                let device_batteryLevelCase: String?
            }
        }
        func percent(_ text: String?) throws -> Int? {
            guard let text else { return nil }
            guard text.hasSuffix("%"), let value = Int(text.dropLast()), (0...100).contains(value) else {
                throw AudioFailure("系统蓝牙报告返回无效电量")
            }
            return value
        }
        let report = try JSONDecoder().decode(Report.self, from: data)
        var result: [String: AppleHeadphoneBattery] = [:]
        for adapter in report.SPBluetoothDataType {
            guard let connected = adapter.device_connected else { continue }
            for entry in connected {
                for device in entry.values {
                    guard let reportedAddress = device.device_address,
                          let address = HeadphonePhysicalIdentity.canonicalAddress(reportedAddress) else { continue }
                    let battery = try AppleHeadphoneBattery(left: percent(device.device_batteryLevelLeft),
                        right: percent(device.device_batteryLevelRight), caseLevel: percent(device.device_batteryLevelCase))
                    guard battery.left != nil || battery.right != nil || battery.caseLevel != nil else { continue }
                    guard result[address] == nil else { throw AudioFailure("系统蓝牙报告包含重复设备地址") }
                    result[address] = battery
                }
            }
        }
        return result
    }
}
