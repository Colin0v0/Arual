import AppKit
import AuralCore

@MainActor
enum RunningApplications {
    static func applications() -> [RunningApplicationInfo] {
        let eligible = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy != .prohibited && $0.processIdentifier != getpid() && $0.bundleURL?.pathExtension == "app"
        }
        return eligible.filter { app in
            guard let bundle = app.bundleURL else { return true }
            // 菜单栏 App 是有效宿主；嵌套在宿主 App 内的 helper 一律不再作为顶层应用，
            // 即使 Electron 类 helper 自己声明为 regular 前台应用，也必须归属到宿主。
            return !eligible.contains { other in
                guard other.processIdentifier != app.processIdentifier, let root = other.bundleURL else { return false }
                return bundle.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
            }
        }.map { app in
            let bundleID: String
            if let value = app.bundleIdentifier { bundleID = value } else { bundleID = "" }
            return RunningApplicationInfo(processID: app.processIdentifier, bundleID: bundleID,
                                          name: app.localizedName, bundleURL: app.bundleURL)
        }
    }

    static func rows(records: [AudioProcessRecord], retainedIDs: Set<String> = [], inventory: ProcessInventory? = nil) -> [ApplicationAudioRow] {
        let facts: ProcessInventory
        if let inventory { facts = inventory }
        else { facts = ProcessInventory.capture(processIDs: records.map(\.processID)) }
        return ApplicationCatalog.rows(applications: applications(), records: records,
                                       executableURLs: facts.executableURLs, retainedIDs: retainedIDs,
                                       parentPIDs: facts.parentPIDs, processNames: facts.names)
    }
}
