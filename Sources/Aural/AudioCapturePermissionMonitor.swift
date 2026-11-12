import Foundation
import Combine
import AuralCore

/// 不显示任何自制权限弹窗。运行期间若权限失效，向系统核验；拒绝后正常退出。
@MainActor
final class AudioCapturePermissionMonitor {
    private var subscription: AnyCancellable?
    private var requestInFlight = false
    private var recoveryFinished = false
    private let currentAccess: () -> SystemAudioCaptureAccess
    private let requestDecision: (@escaping (SystemAudioCaptureAccess) -> Void) -> Void
    private let restartAfterGrant: () -> Void
    private let quitWithoutPermission: () -> Void

    init(access: AnyPublisher<SystemAudioCaptureAccess, Never>,
         currentAccess: @escaping () -> SystemAudioCaptureAccess,
         requestDecision: @escaping (@escaping (SystemAudioCaptureAccess) -> Void) -> Void,
         restartAfterGrant: @escaping () -> Void,
         quitWithoutPermission: @escaping () -> Void) {
        self.currentAccess = currentAccess
        self.requestDecision = requestDecision
        self.restartAfterGrant = restartAfterGrant
        self.quitWithoutPermission = quitWithoutPermission
        subscription = access.receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPermissionIfNeeded() }
        }
    }

    private func checkPermissionIfNeeded() {
        guard !recoveryFinished, !requestInFlight else { return }
        let access = currentAccess()
        if access == .authorized { return }
        if access == .unavailable {
            recoveryFinished = true
            quitWithoutPermission()
            return
        }
        requestInFlight = true
        // 只有系统请求的完成回调可决定是否允许；不从滞后的预检查值伪造授权结果。
        requestDecision { [weak self] decision in
            guard let self, !self.recoveryFinished else { return }
            self.requestInFlight = false
            self.recoveryFinished = true
            if decision == .authorized { self.restartAfterGrant() }
            else { self.quitWithoutPermission() }
        }
    }
}
