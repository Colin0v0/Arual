import AudioToolbox
import CoreAudio
import Foundation

/// 只让系统触发录制授权：不读取输入样本、不写文件、不重放声音。
private let permissionProbeCallback: AudioDeviceIOProc = { _, _, _, _, output, _, _ in
    // 聚合设备没有物理输出；仍明确清空可能存在的输出缓冲。
    for buffer in UnsafeMutableAudioBufferListPointer(output) {
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
    }
    return noErr
}

/// 系统音频没有独立的公开 requestAccess；首次启动包含 tap 的输入才会触发系统申请。
/// 这个对象只保留短生命周期资源，绝不将 API 返回成功当作用户已同意。
@MainActor
public final class AudioPermissionProbe {
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var started = false
    public var isReleased: Bool { tapID == 0 && aggregateID == 0 && ioProc == nil }
    public init() {}

    static func tapDescription() -> CATapDescription {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Aural permission request"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    static func aggregateDescription(tapUUID: UUID) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "Aural permission request",
            kAudioAggregateDeviceUIDKey: "local.aural.permission.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUUID.uuidString,
                                              kAudioSubTapDriftCompensationKey: true]]
        ]
    }

    public func request() throws {
        guard isReleased else { throw AudioFailure("音频授权资源尚未释放") }
        let description = Self.tapDescription()
        do {
            try HAL.check(AudioHardwareCreateProcessTap(description, &tapID), "申请系统音频权限")
            let aggregate = Self.aggregateDescription(tapUUID: description.uuid)
            try HAL.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "创建音频授权输入")
            try HAL.check(AudioDeviceCreateIOProcID(aggregateID, permissionProbeCallback, nil, &ioProc), "创建音频授权回调")
            try HAL.check(AudioDeviceStart(aggregateID, ioProc), "启动系统音频授权申请")
            started = true
        } catch {
            let original = error.localizedDescription
            do { try stop() }
            catch { throw AudioFailure("\(original)；释放授权资源失败：\(error.localizedDescription)") }
            throw AudioFailure(original)
        }
        // 不等待或分析音频帧；只调用公开申请触发点，然后立即释放。
        try stop()
    }

    public func stop() throws {
        // 某一步释放失败就保留剩余资源标识，由调用方报告，不吞错或改走其他授权 API。
        if started {
            try HAL.check(AudioDeviceStop(aggregateID, ioProc), "停止音频授权输入")
            started = false
        }
        if let ioProc {
            try HAL.check(AudioDeviceDestroyIOProcID(aggregateID, ioProc), "释放音频授权回调")
            self.ioProc = nil
        }
        if aggregateID != 0 {
            try HAL.check(AudioHardwareDestroyAggregateDevice(aggregateID), "释放音频授权输入")
            aggregateID = 0
        }
        if tapID != 0 {
            try HAL.check(AudioHardwareDestroyProcessTap(tapID), "释放音频授权 tap")
            tapID = 0
        }
    }
}
