import Foundation
import AuralCore

/// 等待 macOS 的真实授权回调，不创建随后立刻停止的音频探测流，也不把 preflight 当申请结果。
@MainActor
final class AudioCapturePermissionRequest {
    typealias Decision = @Sendable (Bool) -> Void
    private let beginRequest: (@escaping Decision) throws -> Void
    private var continuation: CheckedContinuation<Bool, Error>?
    private var generation: UInt64 = 0
    var isReleased: Bool { continuation == nil }

    init(beginRequest: @escaping (@escaping Decision) throws -> Void) {
        self.beginRequest = beginRequest
    }

    static var live: AudioCapturePermissionRequest {
        AudioCapturePermissionRequest(beginRequest: SystemAudioCaptureAccess.requestAccess)
    }

    func request() async throws -> Bool {
        guard continuation == nil else { throw AudioFailure("系统音频授权请求仍在等待用户决定") }
        generation &+= 1
        let requestGeneration = generation
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                do {
                    try beginRequest { [weak self] granted in
                        Task { @MainActor in self?.finish(.success(granted), generation: requestGeneration) }
                    }
                } catch { finish(.failure(error), generation: requestGeneration) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestGeneration else { return }
                self.cancel()
            }
        }
    }

    func cancel() {
        finish(.failure(CancellationError()), generation: generation)
        generation &+= 1
    }

    private func finish(_ result: Result<Bool, Error>, generation: UInt64) {
        guard self.generation == generation, let continuation else { return }
        self.continuation = nil
        // 先释放等待状态再恢复启动流程，避免把刚返回的系统决定误判成未释放资源。
        continuation.resume(with: result)
    }
}
