import Foundation
import AuralCore
import AppKit

/// 把进程观察、时钟和会话工厂显式注入，完整链路测试不依赖用户正在播放的应用。
@MainActor
struct ApplicationAudioEnvironment {
    var readApplications: (Set<String>) throws -> (rows: [ApplicationAudioRow], processCount: Int)
    var hasMixerConflict: () -> Bool
    var makeSession: (AudioProcessGroup, AudioOutput, ApplicationPlaybackRoute?, ApplicationAudioMode) -> any ApplicationAudioSession
    var now: () -> Date
    /// 测试夹具不读取宿主权限；真实环境明确注入系统只读检查。
    var captureAccess: () -> SystemAudioCaptureAccess

    static var live: Self {
        Self(readApplications: { retained in
            let records = try AudioProcesses.records()
            return (RunningApplications.rows(records: records, retainedIDs: retained), records.count)
        }, hasMixerConflict: {
            AudioMixerConflict.fineTuneIsRunning(bundleIDs: NSWorkspace.shared.runningApplications
                .filter { !$0.isTerminated }.compactMap(\.bundleIdentifier))
        }, makeSession: { group, output, route, mode in
            ProcessAudioSession(group: group, output: output, playbackRoute: route, mode: mode)
        }, now: Date.init, captureAccess: SystemAudioCaptureAccess.current)
    }
}
