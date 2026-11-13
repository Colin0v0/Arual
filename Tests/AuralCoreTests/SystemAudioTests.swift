import Testing
import CoreAudio
@testable import AuralCore

struct SystemAudioTests {
    @Test func invalidObjectStillListedProducesPendingSnapshotInsteadOfPartialSuccess() {
        var nameReads = 0
        do {
            _ = try SystemAudio.readOutputs(
                deviceIDs: [11, 22],
                readStreams: { _ in [1] },
                readUID: { "speaker-\($0)" },
                readName: { id in
                    if id == 22 {
                        nameReads += 1
                        throw AudioFailure("读取音频名称失败", status: HAL.badObjectStatus)
                    }
                    return "扬声器 \(id)"
                },
                readTransport: { _ in kAudioDeviceTransportTypeBuiltIn },
                currentDeviceIDs: { [11, 22] }
            )
            Issue.record("失效对象仍在列表中时，不能返回不完整的成功快照")
        } catch let pending as AudioSnapshotPending {
            #expect(pending.failure.status == HAL.badObjectStatus)
            #expect(nameReads == 2)
        } catch {
            Issue.record("应返回枚举待确认状态，而不是普通失败：\(error)")
        }
    }

    @Test func pendingSnapshotReenumeratesAndRecovers() throws {
        var enumerations = 0
        let outputs = try SystemAudio.readSettledSnapshot {
            enumerations += 1
            let ids: [AudioDeviceID] = enumerations == 1 ? [11, 22] : [11]
            return try SystemAudio.readOutputs(
                deviceIDs: ids,
                readStreams: { _ in [1] },
                readUID: { "speaker-\($0)" },
                readName: { id in
                    if id == 22 { throw AudioFailure("设备正在销毁", status: HAL.badObjectStatus) }
                    return "扬声器 \(id)"
                },
                readTransport: { _ in kAudioDeviceTransportTypeBuiltIn },
                currentDeviceIDs: { ids }
            )
        }
        // 第二次必须重新读取设备表，而不是继续使用已经失效的对象 ID。
        #expect(enumerations == 2)
        #expect(outputs.map(\.id) == [11])
    }

    @Test func persistentPendingSnapshotRemainsAnError() {
        var attempts = 0
        #expect(throws: AudioSnapshotPending.self) {
            try SystemAudio.readSettledSnapshot {
                attempts += 1
                throw AudioSnapshotPending(AudioFailure("设备仍未收敛", status: HAL.badObjectStatus))
            } as Void
        }
        #expect(attempts == 3)
    }

    @Test func ordinarySnapshotFailureIsNotRetried() {
        var attempts = 0
        #expect(throws: AudioFailure.self) {
            try SystemAudio.readSettledSnapshot {
                attempts += 1
                throw AudioFailure("真实属性错误")
            } as Void
        }
        #expect(attempts == 1)
    }

    @Test func invalidVolumeIsRejectedBeforeHardwareAccess() {
        for value: Float in [-0.1, 1.1, .nan, .infinity] {
            #expect(throws: (any Error).self) { try SystemAudio.setVolume(value, on: 0) }
        }
    }

    @Test func transientHALServerRestartIsRetriedInPlace() throws {
        var attempts = 0
        let value = try HAL.retryAfterServerRestart {
            attempts += 1
            if attempts < 3 { throw AudioFailure("HAL 正在重启", status: -308) }
            return 42
        }

        #expect(value == 42)
        #expect(attempts == 3)
    }

    @Test func persistentHALServerRestartStillThrows() {
        var attempts = 0
        #expect(throws: (any Error).self) {
            try HAL.retryAfterServerRestart {
                attempts += 1
                throw AudioFailure("HAL 未恢复", status: -308)
            }
        }
        #expect(attempts == 4)
    }

    @Test func disconnectedDeviceIsSkippedAfterPropertyReadFails() throws {
        var currentReads = 0
        let outputs = try SystemAudio.readOutputs(
            deviceIDs: [11, 22],
            readStreams: { _ in [1] },
            readUID: { id in
                // 22 号设备在枚举后断开；11 号设备仍可正常读取。
                if id == 22 { throw AudioFailure("设备已断开") }
                return "speaker-\(id)"
            },
            readName: { "扬声器 \($0)" },
            readTransport: { _ in kAudioDeviceTransportTypeBuiltIn },
            currentDeviceIDs: {
                currentReads += 1
                return [11]
            }
        )

        #expect(currentReads == 1)
        #expect(outputs.map(\.id) == [11])
        #expect(outputs.map(\.name) == ["扬声器 11"])
    }

    @Test func existingDevicePropertyFailureStillThrows() {
        var didThrow = false
        do {
            _ = try SystemAudio.readOutputs(
                deviceIDs: [11],
                readStreams: { _ in [1] },
                readUID: { _ in "speaker-11" },
                readName: { _ in throw AudioFailure("设备属性读取失败") },
                readTransport: { _ in kAudioDeviceTransportTypeBuiltIn },
                currentDeviceIDs: { [11] }
            )
        } catch {
            didThrow = true
            #expect(error.localizedDescription == "设备属性读取失败")
        }
        #expect(didThrow)
    }

    @Test func deviceThatDisappearsDuringRetryIsSkipped() throws {
        var vanishedDeviceReads = 0
        var currentReads = 0
        let outputs = try SystemAudio.readOutputs(
            deviceIDs: [11, 22],
            readStreams: { _ in [1] },
            readUID: { "speaker-\($0)" },
            readName: { id in
                if id == 22 {
                    vanishedDeviceReads += 1
                    throw AudioFailure("设备正在销毁", status: HAL.badObjectStatus)
                }
                return "扬声器 \(id)"
            },
            readTransport: { _ in kAudioDeviceTransportTypeBuiltIn },
            currentDeviceIDs: {
                currentReads += 1
                // 第一次仍看得到 22 号对象，第二次核对时它已经被系统移除。
                return currentReads == 1 ? [11, 22] : [11]
            }
        )

        #expect(vanishedDeviceReads == 2)
        #expect(currentReads == 2)
        #expect(outputs.map(\.id) == [11])
    }

    @Test func transientPropertyFailureRetriesTheSameDeviceOnce() throws {
        var nameReads = 0
        let outputs = try SystemAudio.readOutputs(
            deviceIDs: [11],
            readStreams: { _ in [1] },
            readUID: { _ in "speaker-11" },
            readName: { _ in
                nameReads += 1
                if nameReads == 1 { throw AudioFailure("设备正在重连") }
                return "扬声器 11"
            },
            readTransport: { _ in kAudioDeviceTransportTypeBuiltIn },
            currentDeviceIDs: { [11] }
        )

        // 设备没有消失但属性读取撞上重连窗口时，允许对同一设备立即重读一次。
        #expect(nameReads == 2)
        #expect(outputs.map(\.id) == [11])
    }

    @Test func outputWithoutOutputStreamsIsSkippedWithoutReadingIdentity() throws {
        var identityReads: [AudioDeviceID] = []
        let outputs = try SystemAudio.readOutputs(
            deviceIDs: [11, 22],
            readStreams: { id in id == 11 ? [] : [1] },
            readUID: { id in
                identityReads.append(id)
                return "speaker-\(id)"
            },
            readName: { "扬声器 \($0)" },
            readTransport: { _ in kAudioDeviceTransportTypeBuiltIn },
            currentDeviceIDs: { [11, 22] }
        )

        // 纯输入或无输出流的设备不需要读取名称与 UID，也不能因此触发错误。
        #expect(identityReads == [22])
        #expect(outputs.map(\.id) == [22])
    }

    @Test func aggregateCompositionRecognizesARealMember() {
        let composition: [String: Any] = [
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: "EC-66-D1-CE-8C-CB:output"],
                [kAudioSubDeviceUIDKey: "BuiltInSpeakerDevice"]
            ]
        ]

        // 多设备输出期间默认 UID 是聚合设备，耳机仍应被识别为当前路由成员。
        #expect(SystemAudio.aggregateCompositionContains("EC-66-D1-CE-8C-CB:output",
                                                         composition: composition as CFDictionary))
        #expect(SystemAudio.aggregateCompositionContains("BuiltInSpeakerDevice",
                                                         composition: composition as CFDictionary))
        #expect(!SystemAudio.aggregateCompositionContains("not-a-member",
                                                          composition: composition as CFDictionary))
    }

    @Test func aggregateCompositionWithoutMemberListDoesNotMatch() {
        let composition: [String: Any] = [kAudioAggregateDeviceNameKey: "不完整聚合"]
        #expect(!SystemAudio.aggregateCompositionContains("member",
                                                          composition: composition as CFDictionary))
    }

    @Test func configuredButInactiveHeadphoneCannotKeepControlAuthorization() {
        let composition: [String: Any] = [kAudioAggregateDeviceSubDeviceListKey: [
            [kAudioSubDeviceUIDKey: "apple"], [kAudioSubDeviceUIDKey: "bw"]
        ]]
        for uid in ["apple", "bw"] {
            #expect(SystemAudio.activeAggregateRouteContains(uid, composition: composition as CFDictionary, activeUIDs: [uid]))
            #expect(!SystemAudio.activeAggregateRouteContains(uid, composition: composition as CFDictionary, activeUIDs: []))
        }
        #expect(!SystemAudio.activeAggregateRouteContains("other", composition: composition as CFDictionary, activeUIDs: ["other"]))
    }

    @Test func versionIsDefined() { #expect(AuralVersion.current == "0.2.2") }
}
