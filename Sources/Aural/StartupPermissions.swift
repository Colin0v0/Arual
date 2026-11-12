import CoreBluetooth
import Foundation
import AuralCore

/// 蓝牙保留首次申请标记；系统音频每次启动都读取真实授权，不信任旧包写入的申请标记。
/// 未决定时直接触发系统“仅系统录音”申请，不在前面叠加 Aural 自己的许可对话框。
struct StartupPermissionResult {
    let errors: [String]
    let canEnterMainInterface: Bool
    var didRequestAudio = false
    var grantedAudioDuringRequest = false
    /// 只有系统授权回调明确返回拒绝时为真；请求接口错误属于另一类启动失败。
    var audioPermissionDenied = false
}

@MainActor
final class StartupPermissionSequence {
    static let bluetoothKey = "Aural.StartupPermissions.BluetoothRequested.v1"
    private let defaults: UserDefaults
    private let requestBluetooth: @MainActor () async -> Bool
    private let audioAccess: @MainActor () -> SystemAudioCaptureAccess
    private let requestAudio: @MainActor () async throws -> Bool
    private let audioIsReleased: @MainActor () -> Bool

    init(defaults: UserDefaults, requestBluetooth: @escaping @MainActor () async -> Bool,
         audioAccess: @escaping @MainActor () -> SystemAudioCaptureAccess,
         requestAudio: @escaping @MainActor () async throws -> Bool,
         audioIsReleased: @escaping @MainActor () -> Bool) {
        self.defaults = defaults
        self.requestBluetooth = requestBluetooth
        self.audioAccess = audioAccess
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
        // 系统录音是进入主界面的必要条件；已拒绝时也只向系统申请一次，由 macOS 决定是否展示。
        // 不自行循环弹窗、不重置 TCC 记录，也不在用户拒绝后展示一套禁用的应用控件。
        let access = audioAccess()
        guard access != .unavailable else {
            return StartupPermissionResult(errors: ["无法检查系统音频录制权限"], canEnterMainInterface: false)
        }
        let shouldRequestAudio = access != .authorized
        var grantedAudio = access == .authorized
        if shouldRequestAudio {
            do {
                grantedAudio = try await requestAudio()
                guard !Task.isCancelled else {
                    return StartupPermissionResult(errors: [], canEnterMainInterface: false)
                }
                guard audioIsReleased() else {
                    return StartupPermissionResult(errors: ["音频授权资源尚未释放"], canEnterMainInterface: false)
                }
            } catch {
                return StartupPermissionResult(errors: [error.localizedDescription], canEnterMainInterface: false)
            }
        }
        return StartupPermissionResult(errors: [], canEnterMainInterface: grantedAudio && audioIsReleased(),
                                       didRequestAudio: shouldRequestAudio,
                                       grantedAudioDuringRequest: shouldRequestAudio && grantedAudio,
                                       audioPermissionDenied: shouldRequestAudio && !grantedAudio)
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
