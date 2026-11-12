import Foundation
import Testing
import AuralCore
@testable import Aural

@MainActor
struct AudioCapturePermissionRequestTests {
    @Test func explicitSystemDecisionIsReturnedWithoutASecondPreflight() async throws {
        for decision in [true, false] {
            let request = AudioCapturePermissionRequest(beginRequest: { completion in completion(decision) })
            let granted = try await request.request()
            #expect(granted == decision)
            #expect(request.isReleased)
        }
    }

    @Test func unavailableRequestAPIThrowsRatherThanPretendingPermissionWasGranted() async {
        let request = AudioCapturePermissionRequest(beginRequest: { _ in throw AudioFailure("测试接口不可用") })
        do {
            _ = try await request.request()
            Issue.record("未报告授权 API 失败")
        } catch { #expect(error.localizedDescription == "测试接口不可用") }
        #expect(request.isReleased)
    }

    @Test func cancellingAnOutstandingRequestDoesNotWaitForTheSystemDialog() async {
        var callback: AudioCapturePermissionRequest.Decision?
        let request = AudioCapturePermissionRequest(beginRequest: { callback = $0 })
        let task = Task { @MainActor in try await request.request() }
        while callback == nil { await Task.yield() }
        #expect(!request.isReleased)
        request.cancel()
        do {
            _ = try await task.value
            Issue.record("取消后仍把请求当作成功")
        } catch { #expect(error is CancellationError) }
        #expect(request.isReleased)
        // 旧系统回调晚到时不能二次恢复 continuation，也不能污染新的请求。
        callback?(true)
        await Task.yield()
        #expect(request.isReleased)
    }
    @Test func cancelledRequestCannotResolveANewerRequestWithItsLateDecision() async throws {
        var callbacks: [AudioCapturePermissionRequest.Decision] = []
        let request = AudioCapturePermissionRequest(beginRequest: { callbacks.append($0) })
        let first = Task { @MainActor in try await request.request() }
        while callbacks.isEmpty { await Task.yield() }
        request.cancel()
        do { _ = try await first.value; Issue.record("旧请求没有被取消") }
        catch { #expect(error is CancellationError) }
        let second = Task { @MainActor in try await request.request() }
        while callbacks.count < 2 { await Task.yield() }
        callbacks[0](true)
        await Task.yield()
        #expect(!request.isReleased)
        callbacks[1](false)
        let granted = try await second.value
        #expect(!granted && request.isReleased)
    }

}
