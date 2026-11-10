import Foundation
import AuralCore

@MainActor
enum HeadphoneDiagnostic {
    /// 仅用于显式的本地硬件验收：沿用真正的自动识别路径，只发 GET，不发 SET。
    static func run() async -> Never {
        let controller = HeadphoneController()
        var result: [String: Any] = ["version": AuralVersion.current]
        var code: Int32 = 1
        do {
            let audio = try SystemAudio.snapshot()
            guard let output = audio.outputs.first(where: { $0.id == audio.selectedID }),
                  controller.supports(output) else {
                throw AudioFailure("当前系统输出没有受支持的耳机驱动；诊断不会替你切换设备。")
            }
            controller.updateOutput(output)
            let limit = Date().addingTimeInterval(45)
            while Date() < limit {
                if controller.phase == .ready, controller.identityVerified, !controller.busy,
                   controller.family == .apple || controller.state.battery != nil {
                    result["status"] = "confirmed"
                    result["physicalIdentityVerified"] = controller.identityVerified
                    result["battery"] = controller.state.battery.map { $0 as Any } ?? NSNull()
                    result["noiseMode"] = controller.state.noiseMode.map { $0.rawValue as Any } ?? NSNull()
                    result["family"] = controller.family?.rawValue
                    result["supportedNoiseModes"] = controller.supportedNoiseModes.map(\.rawValue)
                    code = 0
                    break
                }
                if case .failed = controller.phase, !controller.isReconnecting {
                    var message = controller.phase.title
                    if let detail = controller.errorMessage { message += ": " + detail }
                    throw AudioFailure(message)
                }
                if controller.phase == .choosing {
                    result["status"] = "needs-selection"
                    result["candidates"] = controller.candidates.map { ["name": $0.name, "id": $0.id.uuidString] }
                    code = 2
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            if result["status"] == nil { throw AudioFailure("自动连接诊断超时") }
        } catch {
            result["status"] = "failed"
            result["error"] = error.localizedDescription
        }
        result["trace"] = controller.diagnosticLines
        controller.shutdown()
        // 等待取消确认后才结束，避免紧接着启动主应用时与本诊断竞争控制通道。
        do {
            let cleanupLimit = Date().addingTimeInterval(3)
            while controller.phase == .disconnecting && Date() < cleanupLimit {
                try await Task.sleep(for: .milliseconds(50))
            }
            result["controlClosed"] = controller.phase != .disconnecting
            if controller.phase == .disconnecting { code = 1 }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("诊断结束失败：\(error.localizedDescription)\n".utf8))
            code = 1
        }
        exit(code)
    }
}
