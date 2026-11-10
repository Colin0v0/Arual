import CoreAudio
import Foundation

public struct AudioProcessGroup: Identifiable, Equatable, Codable {
    public let id: String
    public let bundleID: String
    public let processIDs: [Int32]
    public let objectIDs: [AudioObjectID]
    public var label: String { bundleID.isEmpty ? "音频进程 \(processIDs.map(String.init).joined(separator: ", "))" : bundleID }
}

/// 注册音频对象与“正在输出”是两个概念。暂停的播放器仍然需要显示与预配置。
public struct AudioProcessRecord: Equatable, Codable {
    public let objectID: AudioObjectID
    public let processID: Int32
    public let bundleID: String
    public let isRunningOutput: Bool
}

public enum AudioProcesses {
    public static func records() throws -> [AudioProcessRecord] {
        let objects = try HAL.ids(HAL.system, HAL.address(kAudioHardwarePropertyProcessObjectList))
        return try readRecords(
            objectIDs: objects,
            readPID: { try HAL.read($0, HAL.address(kAudioProcessPropertyPID), initial: 0) },
            readRunningOutput: { try HAL.read($0, HAL.address(kAudioProcessPropertyIsRunningOutput), initial: 0) },
            readBundleID: { try HAL.string($0, kAudioProcessPropertyBundleID) },
            currentObjectIDs: {
                try HAL.ids(HAL.system, HAL.address(kAudioHardwarePropertyProcessObjectList))
            }
        )
    }

    /// 读取正在输出进程的真实播放设备。默认输出只是候选，进程对象才是声音实际去了哪里。
    public static func activeOutputDeviceIDs() throws -> [AudioDeviceID] {
        let objects = try HAL.ids(HAL.system, HAL.address(kAudioHardwarePropertyProcessObjectList))
        return try readActiveOutputDeviceIDs(
            objectIDs: objects,
            readPID: { try HAL.read($0, HAL.address(kAudioProcessPropertyPID), initial: 0) },
            readRunningOutput: { try HAL.read($0, HAL.address(kAudioProcessPropertyIsRunningOutput), initial: 0) },
            readDevices: {
                try HAL.ids($0, HAL.address(kAudioProcessPropertyDevices,
                                            scope: kAudioObjectPropertyScopeOutput))
            },
            currentObjectIDs: {
                try HAL.ids(HAL.system, HAL.address(kAudioHardwarePropertyProcessObjectList))
            }
        )
    }

    /// 进程对象可能在枚举后立即退出；消失的对象直接跳过，仍存在的对象重试一次同一只读请求。
    static func readActiveOutputDeviceIDs(objectIDs: [AudioObjectID],
                                          readPID: (AudioObjectID) throws -> Int32,
                                          readRunningOutput: (AudioObjectID) throws -> UInt32,
                                          readDevices: (AudioObjectID) throws -> [AudioDeviceID],
                                          currentObjectIDs: () throws -> [AudioObjectID]) throws -> [AudioDeviceID] {
        var result: Set<AudioDeviceID> = []
        for object in objectIDs {
            var completed = false
            for attempt in 0..<2 where !completed {
                do {
                    guard try readPID(object) != getpid() else {
                        completed = true
                        continue
                    }
                    guard try readRunningOutput(object) != 0 else {
                        completed = true
                        continue
                    }
                    result.formUnion(try readDevices(object))
                    completed = true
                } catch {
                    let stillPresent = try currentObjectIDs().contains(object)
                    guard stillPresent else {
                        completed = true
                        continue
                    }
                    if attempt == 1 { throw error }
                    if let failure = error as? AudioFailure, failure.status == HAL.badObjectStatus {
                        Thread.sleep(forTimeInterval: 0.03)
                    }
                }
            }
        }
        return result.sorted()
    }

    /// 音频进程对象会随播放器创建和退出频繁变化；消失的对象必须跳过，不能拖垮整份音频快照。
    static func readRecords(objectIDs: [AudioObjectID],
                            readPID: (AudioObjectID) throws -> Int32,
                            readRunningOutput: (AudioObjectID) throws -> UInt32,
                            readBundleID: (AudioObjectID) throws -> String,
                            currentObjectIDs: () throws -> [AudioObjectID]) throws -> [AudioProcessRecord] {
        var result: [AudioProcessRecord] = []
        for object in objectIDs {
            var completed = false
            for attempt in 0..<2 where !completed {
                do {
                    let pid = try readPID(object)
                    guard pid != getpid() else {
                        completed = true
                        continue
                    }
                    let running = try readRunningOutput(object)
                    let bundleID = try readBundleID(object)
                    guard !AudioProcessRoles.isMixer(bundleID: bundleID) else {
                        completed = true
                        continue
                    }
                    result.append(AudioProcessRecord(objectID: object, processID: pid,
                                                     bundleID: bundleID,
                                                     isRunningOutput: running != 0))
                    completed = true
                } catch {
                    // 同一个对象只在仍存在时重试一次；确认已退出后直接跳过。
                    let stillPresent = try currentObjectIDs().contains(object)
                    guard stillPresent else {
                        completed = true
                        continue
                    }
                    if attempt == 1 { throw error }
                    if let failure = error as? AudioFailure, failure.status == HAL.badObjectStatus {
                        Thread.sleep(forTimeInterval: 0.03)
                    }
                }
            }
        }
        return result.sorted { $0.objectID < $1.objectID }
    }
}
