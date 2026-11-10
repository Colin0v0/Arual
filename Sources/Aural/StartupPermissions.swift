import CoreBluetooth
import Foundation

/// 只持久化“已触发过申请”，不是伪造一份 TCC 授权状态。
/// 注入申请动作供无权限弹窗的测试验证真实启动顺序，产品始终只有一条公开 API 路径。
struct StartupPermissionResult {
    let errors: [String]
    let canEnterMainInterface: Bool
}

@MainActor
final class StartupPermissionSequence {
    static let bluetoothKey = "Aural.StartupPermissions.BluetoothRequested.v1"
    static let audioKey = "Aural.StartupPermissions.AudioRequested.v1"
    private let defaults: UserDefaults
    private let requestBluetooth: @MainActor () async -> Bool
    private let requestAudio: @MainActor () throws -> Void
    private let audioIsReleased: @MainActor () -> Bool

    init(defaults: UserDefaults, requestBluetooth: @escaping @MainActor () async -> Bool,
         requestAudio: @escaping @MainActor () throws -> Void,
         audioIsReleased: @escaping @MainActor () -> Bool) {
        self.defaults = defaults
        self.requestBluetooth = requestBluetooth
        self.requestAudio = requestAudio
        self.audioIsReleased = audioIsReleased
    }

    func run() async -> StartupPermissionResult {
        guard !Task.isCancelled else { return StartupPermissionResult(errors: [], canEnterMainInterface: false) }
        if !defaults.bool(forKey: Self.bluetoothKey) {
            let determined = await requestBluetooth()
            guard !Task.isCancelled else { return StartupPermissionResult(errors: [], canEnterMainInterface: false) }
            if determined { defaults.set(true, forKey: Self.bluetoothKey) }
        }
        guard !Task.isCancelled else { return StartupPermissionResult(errors: [], canEnterMainInterface: false) }
        if !defaults.bool(forKey: Self.audioKey) {
            do {
                try requestAudio()
                guard audioIsReleased() else {
                    return StartupPermissionResult(errors: ["音频授权资源尚未释放"], canEnterMainInterface: false)
                }
                defaults.set(true, forKey: Self.audioKey)
            } catch {
                return StartupPermissionResult(errors: [error.localizedDescription], canEnterMainInterface: audioIsReleased())
            }
        }
        return StartupPermissionResult(errors: [], canEnterMainInterface: audioIsReleased())
    }
}

/// 初始化 CoreBluetooth 管理器触发系统申请，不扫描、不连接，不额外弹自制说明框。
@MainActor
final class BluetoothPermissionRequest: NSObject {
    private var central: CBCentralManager?
    private var completion: CheckedContinuation<Bool, Never>?

    func request() async -> Bool {
        guard CBManager.authorization == .notDetermined else { return true }
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            return await withCheckedContinuation { completion in
                precondition(self.completion == nil)
                self.completion = completion
                central = CBCentralManager(delegate: self, queue: .main,
                                           options: [CBCentralManagerOptionShowPowerAlertKey: false])
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() { finish(determined: false) }

    private func finish(determined: Bool) {
        let completion = self.completion
        self.completion = nil
        central?.delegate = nil
        central = nil
        completion?.resume(returning: determined)
    }
}

extension BluetoothPermissionRequest: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        if CBManager.authorization != .notDetermined {
            // “拒绝”和“受限制”也是真实系统决定，不在同次启动反复申请。
            finish(determined: true)
        } else if central.state == .unsupported || central.state == .poweredOff {
            // 无法发起决定时不锁死启动，也不记作已授权/已完成；下次启动仍可申请。
            finish(determined: false)
        }
    }
}
