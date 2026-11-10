import CoreAudio
import Foundation
@testable import AuralCore
/// 所有 HAL 读写都只访问内存；用独立媒体/提示音默认值测试分步确认。
@MainActor
final class RoutingTestHardware {
    var outputs = [
        AudioOutput(id: 1, uid: "speaker", name: "测试扬声器", transport: kAudioDeviceTransportTypeBuiltIn),
        AudioOutput(id: 2, uid: "headphone", name: "测试耳机", transport: kAudioDeviceTransportTypeBluetooth),
        AudioOutput(id: 3, uid: "usb", name: "测试 USB", transport: kAudioDeviceTransportTypeUSB)
    ]
    var selected: AudioDeviceID = 1
    var systemSelected: AudioDeviceID = 1
    var pendingSelection: AudioDeviceID?
    var deferSelection = false
    var deferSystemSelection = false
    var failCreation = false
    var failDestroy = false
    var failSnapshotAfterDestroyError = false
    var failSnapshotAfterNextSelection = false
    var afterDestroy: ((AudioDeviceID) -> Void)?
    var failSnapshot = false
    var pendingSnapshot = false
    var snapshotReads = 0
    var keepAfterDestroy = false
    var offline: Set<AudioDeviceID> = []
    var inactive: Set<String> = []
    var activePlayback: [AudioDeviceID] = []
    var compositions: [AudioDeviceID: [String: Any]] = [:]
    var selections: [AudioDeviceID] = []
    var destroyed: [AudioDeviceID] = []
    var created: [AudioDeviceID] = []
    private var nextID: AudioDeviceID = 100

    var snapshot: SystemAudioSnapshot {
        var all = outputs
        for (id, composition) in compositions.sorted(by: { $0.key < $1.key }) {
            if let uid = composition[kAudioAggregateDeviceUIDKey] as? String {
                all.append(AudioOutput(id: id, uid: uid, name: "测试组合", transport: kAudioDeviceTransportTypeAggregate))
            }
        }
        return SystemAudioSnapshot(outputs: all, selectedID: selected, controls: [:])
    }

    func commitSelection() {
        guard let pendingSelection else { return }
        selected = pendingSelection
        systemSelected = pendingSelection
        self.pendingSelection = nil
    }

    var hardware: MultiOutputHardware {
        MultiOutputHardware(snapshot: {
            self.snapshotReads += 1
            if self.failSnapshot { throw AudioFailure("快照读取失败") }
            if self.pendingSnapshot {
                throw AudioSnapshotPending(AudioFailure("读取音频名称失败", status: HAL.badObjectStatus))
            }
            return self.snapshot
        }, selectedSystemOutputID: { self.systemSelected },
            activePlaybackDeviceIDs: { self.activePlayback }, sampleRate: { _ in 48_000 },
            isAlive: { !self.offline.contains($0) }, configuration: { id in
                guard let composition = self.compositions[id],
                      let members = composition[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]] else {
                    throw AudioFailure("组合配置不存在")
                }
                let active = members.compactMap { $0[kAudioSubDeviceUIDKey] as? String }
                    .filter { !self.inactive.contains($0) }
                return try MultiOutputConfiguration(composition: composition, activeOutputUIDs: active)
            }, create: { composition in
                if self.failCreation { throw AudioFailure("新组合创建失败") }
                let id = self.nextID
                self.nextID += 1
                self.compositions[id] = composition
                self.created.append(id)
                return id
            }, select: { id in
                self.selections.append(id)
                if self.failSnapshotAfterNextSelection { self.failSnapshot = true }
                self.pendingSelection = id
                if !self.deferSelection { self.selected = id }
                if !self.deferSelection && !self.deferSystemSelection { self.systemSelected = id }
            }, destroy: { id in
                if self.failDestroy {
                    if self.failSnapshotAfterDestroyError { self.failSnapshot = true }
                    throw AudioFailure("组合释放失败")
                }
                self.destroyed.append(id)
                if !self.keepAfterDestroy { self.compositions.removeValue(forKey: id) }
                self.afterDestroy?(id)
            })
    }
}
