import Foundation

/// 接口派生自 HeadBridge 的 TransportLogEntry，只保存本机有界诊断。
struct TransportLogEntry {
    enum Direction: String { case outgoing = "TX", incoming = "RX", info = "INFO" }
}

enum HeadphoneRouteGuard {
    static func check(_ outputUID: String) throws {
        guard try SystemAudio.selectedRouteContains(outputUID) else {
            throw AudioFailure("系统输出已改变，停止向之前的耳机发送数据")
        }
    }
}
