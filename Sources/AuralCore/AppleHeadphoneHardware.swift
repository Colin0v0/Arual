import CoreAudio
import Foundation

/// Apple 的控制入口可注入内存 HAL 测试；不与 B&W 共用协议，但共用身份、路由和取消规则。
@MainActor
public struct AppleHeadphoneHardware {
    public var isSupported: (AudioDeviceID) -> Bool
    public var validateTarget: (AudioOutput) throws -> Void
    public var snapshot: (AudioDeviceID) throws -> AppleHeadphoneSnapshot
    public var requestMode: (NoiseMode, AudioOutput) throws -> Void
    public var waitForReadback: () async throws -> Void

    public init(isSupported: @escaping (AudioDeviceID) -> Bool,
                validateTarget: @escaping (AudioOutput) throws -> Void,
                snapshot: @escaping (AudioDeviceID) throws -> AppleHeadphoneSnapshot,
                requestMode: @escaping (NoiseMode, AudioOutput) throws -> Void,
                waitForReadback: @escaping () async throws -> Void) {
        self.isSupported = isSupported; self.validateTarget = validateTarget
        self.snapshot = snapshot; self.requestMode = requestMode; self.waitForReadback = waitForReadback
    }

    public static var live: Self {
        Self(isSupported: AppleHeadphoneHAL.isSupported,
             validateTarget: AppleHeadphoneHAL.validateControlTarget,
             snapshot: AppleHeadphoneHAL.snapshot,
             requestMode: AppleHeadphoneHAL.requestNoiseMode,
             waitForReadback: { try await Task.sleep(for: .milliseconds(50)) })
    }
}
