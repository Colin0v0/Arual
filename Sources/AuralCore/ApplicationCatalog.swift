import Foundation

/// 系统应用身份由 AppKit 提供；纯数据模型便于对归属规则做无硬件测试。
public struct RunningApplicationInfo: Equatable, Codable {
    public let processID: Int32
    public let bundleID: String
    public let name: String?
    public let bundleURL: URL?
    public init(processID: Int32, bundleID: String, name: String?, bundleURL: URL?) {
        self.processID = processID; self.bundleID = bundleID; self.name = name; self.bundleURL = bundleURL
    }
}

public struct ApplicationAudioRow: Identifiable, Equatable, Codable {
    public let id: String
    public let bundleID: String
    public let name: String?
    public let applicationURL: URL?
    public let group: AudioProcessGroup?
    public let isRunningOutput: Bool
    public var label: String {
        // 名称来自系统本地化元数据；缺少名称时仍明确显示真实身份，不构造示例 App。
        if let name { return name }
        return bundleID.isEmpty ? id : bundleID
    }
    public var registrationLabel: String {
        if isRunningOutput { return "音频流活跃" }
        return group == nil ? "等待应用创建音频流" : "音频流空闲"
    }
}

public enum ApplicationCatalog {
    /// 主列表只呈现系统报告有输出活动的应用。
    /// 后台目录仍保留空闲成员：隐藏一行不等于销毁它的音频会话或配置。
    public static func playingRows(from rows: [ApplicationAudioRow]) -> [ApplicationAudioRow] {
        rows.filter(\.isRunningOutput)
    }

    public static func rows(applications: [RunningApplicationInfo], records: [AudioProcessRecord],
                            executableURLs: [Int32: URL], retainedIDs: Set<String> = [],
                            parentPIDs: [Int32: Int32] = [:], processNames: [Int32: String] = [:]) -> [ApplicationAudioRow] {
        let apps = Dictionary(grouping: applications) { identity(bundleID: $0.bundleID, pid: $0.processID) }
        var assignments: [String: [AudioProcessRecord]] = [:]
        var unassigned: [AudioProcessRecord] = []
        for record in records {
            guard !AudioProcessRoles.isMixer(bundleID: record.bundleID),
                  !AudioProcessRoles.isInternalService(bundleID: record.bundleID, processName: processNames[record.processID]) else { continue }
            var ancestry: Set<Int32> = []
            var current = record.processID
            while current > 1 && ancestry.count < 64 && ancestry.insert(current).inserted {
                guard let parent = parentPIDs[current] else { break }
                current = parent
            }
            // 证据并列收集，而不是失败后换另一种猜测方式。多重归属有歧义就不合并。
            let owners = apps.filter { _, candidates in
                candidates.contains { app in
                    let samePID = ancestry.contains(app.processID)
                    let sameBundle = !app.bundleID.isEmpty && app.bundleID == record.bundleID
                    let insideBundle: Bool
                    if let executable = executableURLs[record.processID], let bundle = app.bundleURL {
                        insideBundle = executable.standardizedFileURL.path.hasPrefix(bundle.standardizedFileURL.path + "/")
                    } else { insideBundle = false }
                    return samePID || sameBundle || insideBundle
                }
            }.keys
            if owners.count == 1, let owner = owners.first {
                // 先识别到实际宿主再排除，防止混音器 helper 以匿名来源重新出现在列表。
                if let hosts = apps[owner], hosts.contains(where: { AudioProcessRoles.isMixer(bundleID: $0.bundleID) }) { continue }
                assignments[owner, default: []].append(record)
            }
            else { unassigned.append(record) }
        }
        var rows: [ApplicationAudioRow] = apps.filter { _, candidates in
            !candidates.contains { AudioProcessRoles.isMixer(bundleID: $0.bundleID) }
        }.map { key, candidates in
            let app = candidates.sorted { $0.processID < $1.processID }[0]
            let members = assignments[key, default: []]
            return ApplicationAudioRow(id: key, bundleID: app.bundleID, name: app.name,
                                       applicationURL: app.bundleURL, group: makeGroup(id: key, bundleID: app.bundleID, members: members),
                                       isRunningOutput: members.contains { $0.isRunningOutput })
        }
        // 系统守护进程不挤满普通应用列表；确有输出的未知来源保留独立可见行。
        let otherGroups = Dictionary(grouping: unassigned) { identity(bundleID: $0.bundleID, pid: $0.processID) }
        for (key, members) in otherGroups {
            guard members.contains(where: { $0.isRunningOutput }) || retainedIDs.contains("unassigned:\(key)") else { continue }
            // 歧义来源不得与同名 GUI App 的身份冲突。
            let id = "unassigned:\(key)"
            let names = Set(members.compactMap { processNames[$0.processID] })
            guard names.count == 1, let name = names.first else { continue }
            rows.append(ApplicationAudioRow(id: id, bundleID: members[0].bundleID, name: name, applicationURL: nil,
                                            group: makeGroup(id: id, bundleID: members[0].bundleID, members: members), isRunningOutput: members.contains { $0.isRunningOutput }))
        }
        return rows.sorted {
            if $0.isRunningOutput != $1.isRunningOutput { return $0.isRunningOutput }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    public static func identity(bundleID: String, pid: Int32) -> String {
        bundleID.isEmpty ? "pid:\(pid)" : "bundle:\(bundleID)"
    }

    private static func makeGroup(id: String, bundleID: String, members: [AudioProcessRecord]) -> AudioProcessGroup? {
        guard !members.isEmpty else { return nil }
        return AudioProcessGroup(id: id, bundleID: bundleID, processIDs: members.map(\.processID).sorted(),
                                 objectIDs: members.map(\.objectID).sorted())
    }
}
