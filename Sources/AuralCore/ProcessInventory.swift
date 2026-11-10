import Darwin
import Foundation

/// 单一公开的进程元信息快照；不要求目标进程注册到 AppKit。
/// 可执行路径、父 PID 和内核名称是并列事实，不是猜 bundle 前缀的后备链。
public struct ProcessInventory: Codable {
    public var parentPIDs: [Int32: Int32] = [:]
    public var executableURLs: [Int32: URL] = [:]
    public var names: [Int32: String] = [:]
    public var issues: [String] = []
    public init() {}

    public static func capture(processIDs: [Int32]) -> ProcessInventory {
        var result = ProcessInventory()
        var pending = processIDs.map { (pid: $0, depth: 0) }
        var visited: Set<Int32> = []
        while let item = pending.popLast() {
            guard item.pid > 1, item.depth < 64, visited.insert(item.pid).inserted else { continue }
            var bsd = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let read = proc_pidinfo(item.pid, PROC_PIDTBSDINFO, 0, &bsd, size)
            guard read == size else {
                result.issues.append("PID \(item.pid) 的进程信息不可用（libproc \(errno)）")
                continue
            }
            let parent = Int32(bsd.pbi_ppid)
            result.parentPIDs[item.pid] = parent
            if parent > 1 { pending.append((parent, item.depth + 1)) }
            let name = withUnsafeBytes(of: bsd.pbi_name) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !name.isEmpty { result.names[item.pid] = name }
            var path = [CChar](repeating: 0, count: 4096)
            let length = proc_pidpath(item.pid, &path, UInt32(path.count))
            if length > 0 && length < path.count {
                let string = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                result.executableURLs[item.pid] = URL(fileURLWithPath: string)
            } else {
                result.issues.append("PID \(item.pid) 的执行路径不可用（libproc \(errno)）")
            }
        }
        return result
    }
}

public enum AudioProcessRoles {
    public static func isMixer(bundleID: String) -> Bool {
        ["local.aural.app", "com.finetuneapp.finetune"].contains(bundleID.lowercased())
    }

    public static func isInternalService(bundleID: String, processName: String?) -> Bool {
        let services: Set<String> = ["systemsoundserverd", "systemsoundserv", "coreaudiod", "audiomxd"]
        if services.contains(bundleID.lowercased()) { return true }
        if let processName, services.contains(processName.lowercased()) { return true }
        return false
    }
}
