import AppKit
import CoreAudio
import Foundation
import Testing
@testable import AuralCore
@testable import Aural

@MainActor
struct OutputRoutingIntegrationTests {
    @Test func transientBluetoothSnapshotPendingDoesNotLatchAnOutputError() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment)
        let initialAudio = model.audio

        // 模拟 macOS 已把媒体默认输出切到耳机，但输出流尚未出现在本次 HAL 枚举中的瞬间。
        hardware.selected = 2
        hardware.systemSelected = 3
        hardware.pendingSnapshot = true
        model.refresh()

        #expect(model.audio == initialAudio)
        #expect(model.audioError == nil)
        #expect(model.outputRouting.phase == .stable)
        #expect(model.outputRouting.error == nil)

        hardware.pendingSnapshot = false
        model.refresh()

        #expect(model.audio?.selectedID == 2)
        #expect(model.outputRouting.actualOutput?.id == 2)
        #expect(model.outputRouting.actualSystemOutputID == 3)
        #expect(model.outputRouting.error == nil)
        #expect(model.shutdown())
    }

    @Test func sustainedSnapshotPendingStillReportsAfterTheSettleWindow() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment)

        hardware.pendingSnapshot = true
        model.refresh()
        #expect(model.outputRouting.phase == .stable)
        #expect(model.audioError == nil)

        // 超过三秒仍未收敛就是真实读取失败，必须显示错误，不能无限等待或伪装成功。
        audio.now = audio.now.addingTimeInterval(3.1)
        model.refresh()
        #expect(model.audio == nil)
        #expect(model.audioError != nil)
        #expect(model.outputRouting.phase == .failed)
        #expect(model.outputRouting.error != nil)
        #expect(model.shutdown())
    }

    @Test func removingAnEarphoneContinuesManagedAudioOnOtherSelectedMembersWithoutReapplying() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment, userIsSelectingOutput: { false })
        let applicationID = audio.row.id
        model.setApplicationGain(0.58, for: applicationID)
        model.toggleApplicationMute(applicationID)
        #expect(model.startSimultaneousOutput(["speaker", "headphone", "usb"]))
        for _ in 0..<10 {
            hardware.offline.insert(2)
            hardware.selected = 2
            hardware.systemSelected = 2
            model.refresh()
            #expect(model.outputRouting.phase == .confirmed)
            #expect(model.outputRouting.selectedMemberUIDs == ["speaker", "headphone", "usb"])
            #expect(model.outputRouting.unavailableMemberUIDs == ["headphone"])
            #expect(audio.sessions.last?.playbackUIDs == ["speaker", "usb"])
            #expect(audio.sessions.last?.isActive == true)
            #expect(audio.sessions.last?.gain == 0.58)
            #expect(audio.sessions.last?.muted == true)
            #expect(model.mixStates[applicationID]?.failure == nil)
            #expect(model.outputRouting.pendingCleanup.isEmpty)
            #expect(model.outputRouting.error == nil && model.outputRouting.warning == nil)
            hardware.offline.remove(2)
            audio.now = audio.now.addingTimeInterval(1)
            model.refresh()
            audio.now = audio.now.addingTimeInterval(0.6)
            model.refresh()
            #expect(audio.sessions.last?.playbackUIDs == ["speaker", "headphone", "usb"])
            #expect(audio.sessions.last?.isActive == true)
            #expect(audio.sessions.last?.gain == 0.58)
            #expect(audio.sessions.last?.muted == true)
        }
        #expect(model.shutdown())
    }

    @Test func outputSwitchKeepsApplicationRowsOrderGainsAndLevelSourceIdentity() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let browser = ApplicationAudioRow(id: "bundle:test.browser", bundleID: "test.browser",
                                         name: "测试浏览器", applicationURL: nil, group: nil,
                                         isRunningOutput: true)
        audio.additionalRows = [browser]
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment)
        let initialIDs = model.playingApplications.map(\.id)
        let source = model.levelSource(for: audio.row.id)
        let browserSource = model.levelSource(for: browser.id)
        model.setApplicationGain(0.58, for: audio.row.id)
        model.setApplicationGain(0.8, for: browser.id)
        model.toggleApplicationMute(audio.row.id)

        hardware.deferSelection = true
        model.selectOutput(2)
        audio.playing = false
        model.refresh()
        #expect(model.outputRouting.phase == .awaitingHAL)
        #expect(model.playingApplications.map(\.id) == initialIDs)
        #expect(model.applications.first { $0.id == audio.row.id }?.isRunningOutput == false)
        #expect(model.levelSource(for: audio.row.id) === source)
        #expect(model.levelSource(for: browser.id) === browserSource)
        #expect(source.level == nil)

        hardware.deferSelection = false
        hardware.commitSelection()
        model.refresh()
        #expect(model.outputRouting.phase == .confirmed)
        #expect(model.playingApplications.map(\.id) == initialIDs)
        audio.playing = true
        audio.now = audio.now.addingTimeInterval(1)
        model.refresh()
        #expect(model.playingApplications.map(\.id) == initialIDs)
        #expect(model.mixStates[audio.row.id]?.gain == 0.58)
        #expect(model.mixStates[audio.row.id]?.muted == true)
        #expect(model.mixStates[browser.id]?.gain == 0.8)
        #expect(model.levelSource(for: audio.row.id) === source)
        #expect(model.levelSource(for: browser.id) === browserSource)
        #expect(model.shutdown())
    }

    @Test func presentationGraceNeverReusesVanishedProcessesAndExpiresAfterConfirmation() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment)
        let applicationID = audio.row.id
        model.setApplicationGain(0.58, for: applicationID)
        let source = model.levelSource(for: applicationID)
        model.selectOutput(2)
        audio.omitsApplication = true
        model.refresh()

        #expect(model.applications.isEmpty)
        #expect(model.playingApplications.map(\.id) == [applicationID])
        #expect(model.playingApplications.first?.group == nil)
        #expect(model.playingApplications.first?.isRunningOutput == false)
        #expect(model.sessions.isEmpty)
        #expect(model.levelSource(for: applicationID) === source)
        #expect(source.level == nil)
        let sessionCount = audio.sessions.count
        audio.now = audio.now.addingTimeInterval(3.1)
        model.refresh()
        #expect(model.playingApplications.isEmpty)
        #expect(audio.sessions.count == sessionCount)
        #expect(model.mixStates[applicationID]?.gain == 0.58)

        // 稳定路由上的普通暂停不延迟隐藏，展示保护只围绕设备切换生效。
        audio.omitsApplication = false
        model.refresh()
        #expect(model.playingApplications.map(\.id) == [applicationID])
        audio.playing = false
        model.refresh()
        #expect(model.playingApplications.isEmpty)
        #expect(model.shutdown())
    }

    @Test func failedRouteDoesNotKeepHistoricalApplicationRowsVisible() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment)
        hardware.deferSelection = true
        model.selectOutput(2)
        audio.omitsApplication = true
        model.refresh()
        #expect(!model.playingApplications.isEmpty)
        audio.now = audio.now.addingTimeInterval(4)
        model.refresh()
        #expect(model.outputRouting.phase == .failed)
        #expect(model.playingApplications.isEmpty)
        #expect(model.sessions.isEmpty)
    }

    @Test func repeatedStaleNamesDuringReleaseResumeTheSameRequestAndKeepAppGain() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment)
        model.setApplicationGain(0.37, for: audio.row.id)

        for _ in 0..<20 {
            hardware.afterDestroy = nil
            #expect(model.startSimultaneousOutput(["speaker", "headphone"]))
            let destroyCount = hardware.destroyed.count
            hardware.afterDestroy = { _ in hardware.pendingSnapshot = true }
            model.selectOutput(2)
            #expect(model.outputRouting.phase == .awaitingHAL)
            #expect(model.audioError == nil)
            #expect(model.multiOutputError == nil)

            // 包括 AppModel 最外层快照读取也撞到旧句柄的情况，必须等待原请求，不能锁存 APP 失败。
            audio.now = audio.now.addingTimeInterval(0.1)
            model.refresh()
            #expect(model.outputRouting.phase == .awaitingHAL)
            #expect(model.audioError == nil)
            #expect(model.mixStates[audio.row.id]?.failure == nil)
            #expect(hardware.destroyed.count == destroyCount + 1)

            hardware.pendingSnapshot = false
            model.refresh()
            #expect(model.outputRouting.phase == .confirmed)
            #expect(model.outputRouting.confirmed?.output.uid == "headphone")
            #expect(model.outputRouting.pendingCleanup.isEmpty)
            #expect(audio.sessions.last?.isActive == true)
            #expect(audio.sessions.last?.gain == 0.37)
            #expect(hardware.destroyed.count == destroyCount + 1)
        }
        #expect(model.shutdown())
    }

    @Test func gainZeroMuteAndPauseSurviveOneTwoOneTwoOnEitherRemainingDevice() throws {
        for retained in ["speaker", "headphone"] {
            for kind in ["zero", "muted", "paused"] {
                let hardware = RoutingTestHardware()
                let audio = SessionFixture()
                let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false, applicationAudio: audio.environment)
                let id = audio.row.id
                if kind == "zero" { model.setApplicationGain(0, for: id) }
                else { model.setApplicationGain(0.37, for: id) }
                if kind == "muted" { model.toggleApplicationMute(id) }
                if kind == "paused" { audio.playing = false; model.refresh() }

                for uids in [[retained], ["speaker", "headphone"], [retained], ["speaker", "headphone"]] {
                    #expect(model.startSimultaneousOutput(uids))
                    #expect(model.outputRouting.selectedMemberUIDs == uids)
                    #expect(model.mixStates[id]?.gain == (kind == "zero" ? 0 : 0.37))
                    #expect(model.mixStates[id]?.muted == (kind == "muted"))
                    #expect(model.mixStates[id]?.failure == nil)
                    let session = try #require(audio.sessions.last)
                    #expect(session.isActive)
                    #expect(session.output.uid == model.outputRouting.confirmed?.output.uid)
                    #expect(session.playbackUIDs == uids || Set(session.playbackUIDs) == Set(uids))
                    #expect(audio.sessions.dropLast().allSatisfy { $0.isReleased })
                }
                // 取消静音、从零恢复或恢复播放，都不得需要重新应用。
                if kind == "muted" { model.toggleApplicationMute(id) }
                model.setApplicationGain(0.7, for: id)
                audio.playing = true; model.refresh()
                #expect(audio.sessions.last?.gain == 0.7)
                #expect(audio.sessions.last?.muted == false)
                #expect(model.mixStates[id]?.failure == nil)
                #expect(model.shutdown())
            }
        }
    }

    @Test func delayedReleaseDoesNotLatchAppFailuresOrRequireRestart() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false, applicationAudio: audio.environment)
        model.setApplicationGain(0, for: audio.row.id)
        #expect(model.startSimultaneousOutput(["speaker", "headphone"]))
        hardware.keepAfterDestroy = true
        model.selectOutput(2)
        #expect(model.outputRouting.phase == .awaitingHAL)
        #expect(model.multiOutputError == nil)
        #expect(model.mixStates[audio.row.id]?.failure == nil)
        #expect(model.mixStates[audio.row.id]?.gain == 0)
        #expect(model.sessions.isEmpty)
        let destroyCount = hardware.destroyed.count
        model.refresh()
        #expect(hardware.destroyed.count == destroyCount)
        // HAL 在后续通知中移除设备，APP 应在同一实例自动恢复，不能要求退出重开。
        hardware.compositions.removeAll()
        model.refresh()
        #expect(model.outputRouting.phase == .confirmed)
        #expect(model.outputRouting.confirmed?.output.uid == "headphone")
        #expect(model.multiOutputError == nil)
        #expect(model.mixStates[audio.row.id]?.failure == nil)
        #expect(audio.sessions.last?.isActive == true)
        #expect(audio.sessions.last?.gain == 0)
        model.setApplicationGain(0.7, for: audio.row.id)
        #expect(audio.sessions.last?.gain == 0.7)
        #expect(model.shutdown())
    }

    @Test func waitingForHALNeverStartsASessionOnAnUnconfirmedRoute() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false, applicationAudio: audio.environment)
        model.setApplicationGain(0, for: audio.row.id)
        hardware.deferSelection = true
        #expect(!model.startSimultaneousOutput(["speaker", "headphone"]))
        #expect(model.outputRouting.phase == .awaitingHAL)
        #expect(model.sessions.isEmpty)
        #expect(model.mixStates[audio.row.id]?.failure == nil)
        hardware.deferSelection = false; hardware.commitSelection()
        model.refresh()
        #expect(model.outputRouting.phase == .confirmed)
        #expect(audio.sessions.last?.gain == 0)
        #expect(model.mixStates[audio.row.id]?.failure == nil)
        #expect(model.shutdown())
    }

    @Test func transientAppRoutePropagationWaitsWithoutLatchingAndKeepsZeroIntent() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false, applicationAudio: audio.environment)
        model.setApplicationGain(0, for: audio.row.id)
        audio.routePending = true
        #expect(model.startSimultaneousOutput(["speaker", "headphone"]))
        #expect(model.sessions.isEmpty)
        #expect(model.mixStates[audio.row.id]?.failure == nil)
        audio.now = audio.now.addingTimeInterval(1)
        model.refresh()
        #expect(model.mixStates[audio.row.id]?.failure == nil)
        audio.routePending = false
        model.refresh()
        #expect(audio.sessions.last?.isActive == true)
        #expect(audio.sessions.last?.gain == 0)
        model.setApplicationGain(0.6, for: audio.row.id)
        #expect(audio.sessions.last?.gain == 0.6)
        #expect(model.shutdown())
    }

    @Test func persistentAppRouteMismatchHasADeadlineButPermissionErrorsStayLatched() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false, applicationAudio: audio.environment)
        audio.routePending = true
        model.setApplicationGain(0.3, for: audio.row.id)
        audio.now = audio.now.addingTimeInterval(4)
        model.refresh()
        #expect(model.mixStates[audio.row.id]?.failure != nil)
        audio.routePending = false
        model.refresh()
        #expect(model.sessions.isEmpty)
        model.applyApplication(audio.row.id)
        #expect(model.mixStates[audio.row.id]?.failure == nil)
        audio.startError = AudioFailure("录制权限被拒绝")
        #expect(model.startSimultaneousOutput(["speaker", "headphone"]))
        #expect(model.mixStates[audio.row.id]?.failure == "录制权限被拒绝")
        audio.startError = nil
        #expect(model.updateSimultaneousOutput(["speaker"]))
        #expect(model.mixStates[audio.row.id]?.failure == "录制权限被拒绝")
        #expect(model.sessions.isEmpty)
        #expect(model.shutdown())
    }

    @Test func explicitRetryStartsANewAppPropagationDeadline() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false, applicationAudio: audio.environment)
        audio.routePending = true
        model.setApplicationGain(0, for: audio.row.id)
        audio.now = audio.now.addingTimeInterval(4)
        model.refresh()
        #expect(model.mixStates[audio.row.id]?.failure != nil)
        model.applyApplication(audio.row.id)
        #expect(model.mixStates[audio.row.id]?.failure == nil)
        audio.now = audio.now.addingTimeInterval(1)
        audio.routePending = false
        model.refresh()
        #expect(audio.sessions.last?.isActive == true)
        #expect(audio.sessions.last?.gain == 0)
        #expect(model.shutdown())
    }

    @Test func appRetryContinuesAfterAsynchronousGlobalRecoveryWithoutAnotherClick() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false, applicationAudio: audio.environment)
        audio.routePending = true
        model.setApplicationGain(0, for: audio.row.id)
        audio.now = audio.now.addingTimeInterval(4)
        model.refresh()
        #expect(model.mixStates[audio.row.id]?.failure != nil)
        hardware.deferSystemSelection = true
        #expect(!model.startSimultaneousOutput(["headphone"]))
        audio.now = audio.now.addingTimeInterval(4)
        model.refresh() // 主动切换超时是真实失败，和系统正常分离默认输出不同。
        #expect(model.outputRouting.phase == .failed)
        model.applyApplication(audio.row.id)
        #expect(model.outputRouting.phase == .awaitingHAL)
        #expect(model.mixStates[audio.row.id]?.failure != nil)
        #expect(model.sessions.isEmpty)
        hardware.deferSystemSelection = false; hardware.commitSelection()
        // 保持 APP 仍在传播中，确认重试得到新预算而非沿用旧的超时。
        audio.now = audio.now.addingTimeInterval(1)
        model.refresh()
        #expect(model.outputRouting.phase == .confirmed)
        #expect(model.mixStates[audio.row.id]?.failure == nil)
        audio.routePending = false
        audio.now = audio.now.addingTimeInterval(1)
        model.refresh()
        #expect(audio.sessions.last?.isActive == true)
        #expect(audio.sessions.last?.gain == 0)
        #expect(audio.sessions.last?.playbackUIDs == ["headphone"])
        #expect(model.shutdown())
    }

    @Test func appControlsKeepWorkingAfterExternalSwitchWithoutReapplying() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment,
                             userIsSelectingOutput: { true })
        model.setApplicationGain(0, for: audio.row.id)
        #expect(model.startSimultaneousOutput(["speaker", "headphone"]))
        hardware.selected = 2; hardware.systemSelected = 2
        model.refresh()
        #expect(model.outputRouting.phase == .stable)
        #expect(model.mixStates[audio.row.id]?.failure == nil)
        #expect(model.outputRouting.confirmed?.output.uid == "headphone")
        #expect(model.mixStates[audio.row.id]?.failure == nil)
        #expect(audio.sessions.last?.isActive == true)
        #expect(audio.sessions.last?.playbackUIDs == ["headphone"])
        #expect(audio.sessions.last?.gain == 0)
        model.refresh()
        #expect(model.mixStates[audio.row.id]?.failure == nil)
        #expect(model.shutdown())
    }

    @Test func modelAndSessionUseTheSameObservedRoutingSnapshot() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment,
                             userIsSelectingOutput: { true })
        #expect(hardware.snapshotReads == 1)
        model.setApplicationGain(0.4, for: audio.row.id)
        hardware.selected = 2; hardware.systemSelected = 2
        model.refresh()
        // 外部媒体变化这一轮就迁移会话；不重写默认输出，也不沿用旧目标。
        #expect(hardware.snapshotReads == 2)
        #expect(model.audio?.selectedID == model.outputRouting.actualOutput?.id)
        #expect(model.audio?.selectedID == 2)
        #expect(model.outputRouting.confirmed?.output.uid == "headphone")
        #expect(audio.sessions.last?.playbackUIDs == ["headphone"])
        #expect(audio.sessions.dropLast().allSatisfy { $0.isReleased })
        #expect(model.shutdown())
    }

    @Test func separateSoundEffectOutputDoesNotBlockAppControlsAtStartup() {
        let hardware = RoutingTestHardware()
        hardware.systemSelected = 2
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false, applicationAudio: audio.environment)
        model.setApplicationGain(0.3, for: audio.row.id)
        #expect(model.outputRouting.confirmed?.output.uid == "speaker")
        #expect(audio.sessions.last?.isActive == true)
        #expect(model.multiOutputError == nil)
        model.selectOutput(1)
        #expect(model.outputRouting.phase == .confirmed)
        #expect(audio.sessions.last?.isActive == true)
        #expect(model.shutdown())
    }

    @Test func aNewObservationFailureRevokesAnOlderPendingAppRetry() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false, applicationAudio: audio.environment)
        model.setApplicationGain(0.3, for: audio.row.id)
        hardware.deferSelection = true
        #expect(!model.startSimultaneousOutput(["speaker", "headphone"]))
        model.applyApplication(audio.row.id)
        audio.readError = AudioFailure("注入：进程枚举失败")
        model.refresh()
        #expect(model.mixStates[audio.row.id]?.failure?.contains("进程枚举失败") == true)
        audio.readError = nil
        hardware.deferSelection = false; hardware.commitSelection()
        model.refresh()
        #expect(model.outputRouting.phase == .confirmed)
        // 旧的重试不能授权清除它之后才发生的新错误，必须再明确重新应用。
        #expect(model.mixStates[audio.row.id]?.failure?.contains("进程枚举失败") == true)
        #expect(model.sessions.isEmpty)
        model.applyApplication(audio.row.id)
        #expect(model.mixStates[audio.row.id]?.failure == nil)
        #expect(audio.sessions.last?.isActive == true)
        #expect(model.shutdown())
    }

    @Test func activeSessionHealthFailuresPreserveIntentAndOnlyTransientRoutesCanResume() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false, applicationAudio: audio.environment)
        model.setApplicationGain(0, for: audio.row.id)
        audio.routePending = true
        audio.healthError = ApplicationRoutePending()
        model.refresh()
        #expect(model.sessions.isEmpty)
        #expect(model.mixStates[audio.row.id]?.failure == nil)
        audio.routePending = false; audio.healthError = nil
        model.refresh()
        #expect(audio.sessions.last?.gain == 0)
        #expect(audio.sessions.last?.isActive == true)

        audio.healthError = AudioFailure("实时缓冲布局不匹配")
        model.refresh()
        #expect(model.mixStates[audio.row.id]?.failure == "实时缓冲布局不匹配")
        #expect(model.sessions.isEmpty)
        audio.healthError = nil
        #expect(model.startSimultaneousOutput(["speaker", "headphone"]))
        #expect(model.mixStates[audio.row.id]?.failure == "实时缓冲布局不匹配")
        model.applyApplication(audio.row.id)
        #expect(audio.sessions.last?.gain == 0)
        #expect(audio.sessions.last?.isActive == true)
        #expect(model.shutdown())
    }

    @Test func failedNewCompositionStopsReplayingToRemovedMembersAndDoesNotRestoreCheckmarks() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false, applicationAudio: audio.environment)
        model.setApplicationGain(0.4, for: audio.row.id)
        #expect(model.startSimultaneousOutput(["speaker", "headphone"]))
        hardware.failCreation = true
        #expect(!model.updateSimultaneousOutput(["headphone", "usb"]))
        #expect(model.outputRouting.phase == .failed)
        #expect(model.outputRouting.actualOutput?.uid == "headphone")
        #expect(model.outputRouting.selectedMemberUIDs.isEmpty)
        #expect(audio.sessions.allSatisfy { $0.isReleased })
        #expect(model.mixStates[audio.row.id]?.gain == 0.4)
        hardware.failCreation = false
        #expect(model.startSimultaneousOutput(["headphone"]))
        #expect(audio.sessions.last?.playbackUIDs == ["headphone"])
        #expect(model.mixStates[audio.row.id]?.failure == nil)
        #expect(model.shutdown())
    }

    @Test func resourceCleanupFailureBlocksRouteWritesAndCannotBeHiddenByRebinding() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false, applicationAudio: audio.environment)
        model.setApplicationGain(0.2, for: audio.row.id)
        audio.sessions.last?.failStop = true
        let writes = hardware.selections.count
        #expect(!model.startSimultaneousOutput(["speaker", "headphone"]))
        #expect(hardware.selections.count == writes)
        #expect(!model.cleanupErrors.isEmpty)
        #expect(model.mixStates[audio.row.id]?.failure != nil)
        audio.sessions.last?.failStop = false
        model.applyApplication(audio.row.id)
        #expect(model.cleanupErrors.isEmpty)
        #expect(model.shutdown())
    }

    @Test func externalBluetoothSwitchMovesAppSessionsWithoutStealingTheOutputBack() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment,
                             userIsSelectingOutput: { true })
        model.setApplicationGain(0, for: audio.row.id)
        #expect(model.startSimultaneousOutput(["speaker", "headphone"]))
        let writes = hardware.selections.count
        hardware.selected = 2; hardware.systemSelected = 2
        model.refresh()
        #expect(hardware.selections.count == writes)
        #expect(model.outputRouting.phase == .stable)
        #expect(model.multiOutputError == nil)
        #expect(audio.sessions.last?.playbackUIDs == ["headphone"])
        #expect(model.mixStates[audio.row.id]?.failure == nil)
        #expect(model.mixStates[audio.row.id]?.gain == 0)
        model.selectOutput(2)
        #expect(model.outputRouting.phase == .confirmed)
        #expect(audio.sessions.last?.playbackUIDs == ["headphone"])
        #expect(model.shutdown())
    }

    @Test func appleTakeoverWhileManagedSessionIsActiveRestoresTheConfirmedRoute() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment,
                             userIsSelectingOutput: { false })
        model.setApplicationGain(0, for: audio.row.id)
        #expect(model.startSimultaneousOutput(["speaker", "headphone"]))
        let aggregateID = hardware.selected
        let writes = hardware.selections.count
        let sessionCount = audio.sessions.count

        // 用户没有在系统界面选择输出，默认变化来自 AirPods 抢占；
        // Aural 会话仍在原组合上重放，必须恢复默认输出而不是拆掉会话。
        hardware.selected = 2
        hardware.systemSelected = 2
        model.refresh()
        #expect(hardware.selected == aggregateID && hardware.systemSelected == aggregateID)
        #expect(hardware.selections.count == writes + 1)
        #expect(audio.sessions.count == sessionCount)
        #expect(audio.sessions.last?.isActive == true)
        #expect(model.outputRouting.confirmed?.aggregate != nil)
        #expect(model.outputRouting.error == nil)
        #expect(model.shutdown())
    }

    @Test func finalMemberCannotBeRemovedAndCollapseDoesNotChangeModelPlayback() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false, applicationAudio: audio.environment)
        model.setApplicationGain(0.3, for: audio.row.id)
        model.toggleSimultaneousMember("headphone")
        let writes = hardware.selections.count
        let sessions = audio.sessions.count
        let disclosure = OutputRoutingDisclosure()
        disclosure.isChoosing = true; disclosure.cancel()
        model.toggleSimultaneousMember("headphone")
        #expect(model.outputRouting.selectedMemberUIDs == ["headphone"])
        #expect(model.outputRouting.isSimultaneous)
        #expect(hardware.selections.count == writes)
        #expect(audio.sessions.count == sessions)
        #expect(audio.sessions.last?.isActive == true)
        #expect(model.shutdown())
    }

    @Test func perAppCustomRoutesUseIndependentPlaybackDeviceSets() throws {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let browser = applicationRow(bundleID: "test.browser", name: "Google Chrome", objectID: 43)
        let spotify = applicationRow(bundleID: "test.spotify", name: "Spotify", objectID: 44)
        audio.additionalRows = [browser, spotify]
        let suite = "Aural.RouteIntegration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment,
                             appAudioRouteStore: AppAudioRouteStore(defaults: defaults))

        #expect(model.startSimultaneousOutput(["speaker", "headphone"]))
        model.setApplicationAudioRoute(.custom(deviceUIDs: ["speaker"]), for: browser.id)
        model.setApplicationAudioRoute(.custom(deviceUIDs: ["headphone"]), for: spotify.id)

        let browserSession = try #require(audio.sessions.last { $0.group.bundleID == "test.browser" })
        let spotifySession = try #require(audio.sessions.last { $0.group.bundleID == "test.spotify" })
        #expect(browserSession.playbackUIDs == ["speaker"])
        #expect(spotifySession.playbackUIDs == ["headphone"])
        #expect(browserSession.isActive && spotifySession.isActive)

        // 修改 Chrome 的路由不能重建或改变 Spotify 的会话。
        model.setApplicationAudioRoute(.custom(deviceUIDs: ["speaker", "headphone"]), for: browser.id)
        #expect(audio.sessions.last { $0.group.bundleID == "test.spotify" } === spotifySession)
        #expect(audio.sessions.last { $0.group.bundleID == "test.browser" }?.playbackUIDs == ["speaker", "headphone"])

        // 应用音量仍是独立控制，不携带或改写路由目标。
        model.setApplicationGain(0.42, for: browser.id)
        #expect(audio.sessions.last { $0.group.bundleID == "test.browser" }?.playbackUIDs == ["speaker", "headphone"])
        #expect(audio.sessions.last { $0.group.bundleID == "test.browser" }?.gain == 0.42)
        #expect(model.shutdown())
    }

    @Test func removingTheLastAppRouteTargetIsIgnoredWithoutAnError() throws {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let browser = applicationRow(bundleID: "test.browser", name: "Google Chrome", objectID: 43)
        audio.additionalRows = [browser]
        let suite = "Aural.RouteIntegration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment,
                             appAudioRouteStore: AppAudioRouteStore(defaults: defaults))

        #expect(model.startSimultaneousOutput(["speaker", "headphone"]))
        model.setApplicationAudioRoute(.custom(deviceUIDs: ["speaker"]), for: browser.id)
        model.toggleApplicationAudioRouteDevice("speaker", for: browser.id)

        // 最后一个目标保持勾选，重复取消不产生顶部错误提示。
        #expect(model.applicationAudioRoute(for: browser.id) == .custom(deviceUIDs: ["speaker"]))
        #expect(model.operationError == nil)
        #expect(model.shutdown())
    }

    @Test func customRouteUpdatesWhenMembersAreAddedOrRemoved() throws {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let browser = applicationRow(bundleID: "test.browser", name: "Google Chrome", objectID: 43)
        audio.additionalRows = [browser]
        let suite = "Aural.RouteIntegration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment,
                             appAudioRouteStore: AppAudioRouteStore(defaults: defaults))

        #expect(model.startSimultaneousOutput(["speaker", "headphone"]))
        model.setApplicationAudioRoute(.custom(deviceUIDs: ["speaker"]), for: browser.id)
        #expect(model.applicationAudioRoute(for: browser.id) == .custom(deviceUIDs: ["speaker"]))

        #expect(model.updateSimultaneousOutput(["speaker", "headphone", "usb"]))
        #expect(model.applicationAudioRoute(for: browser.id) == .custom(deviceUIDs: ["speaker"]))

        #expect(model.updateSimultaneousOutput(["headphone", "usb"]))
        // 用户从组里移除 speaker 后，自定义意图不能继续指向组外设备。
        #expect(model.applicationAudioRoute(for: browser.id) == .allOutputs)
        #expect(model.appAudioRoutes["bundle:test.browser"] == nil)
        #expect(model.shutdown())
    }

    @Test func temporarilyDisconnectedCustomTargetFallsBackThenRestoresByUID() throws {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let browser = applicationRow(bundleID: "test.browser", name: "Google Chrome", objectID: 43)
        audio.additionalRows = [browser]
        let suite = "Aural.RouteIntegration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment,
                             appAudioRouteStore: AppAudioRouteStore(defaults: defaults))

        #expect(model.startSimultaneousOutput(["speaker", "headphone"]))
        model.setApplicationAudioRoute(.custom(deviceUIDs: ["headphone"]), for: browser.id)
        #expect(model.effectiveApplicationAudioRoute(for: browser.id) == .custom(deviceUIDs: ["headphone"]))

        hardware.offline.insert(2)
        hardware.inactive.insert("headphone")
        for _ in 0..<6 {
            audio.now = audio.now.addingTimeInterval(0.1)
            model.refresh()
        }
        #expect(model.applicationAudioRoute(for: browser.id) == .custom(deviceUIDs: ["headphone"]))
        #expect(model.effectiveApplicationAudioRoute(for: browser.id) == .allOutputs)

        hardware.offline.remove(2)
        hardware.inactive.remove("headphone")
        for _ in 0..<20 {
            audio.now = audio.now.addingTimeInterval(0.1)
            model.refresh()
            if model.applicationAudioRoutingEnabled,
               model.effectiveApplicationAudioRoute(for: browser.id) == .custom(deviceUIDs: ["headphone"]) {
                break
            }
        }
        #expect(model.effectiveApplicationAudioRoute(for: browser.id) == .custom(deviceUIDs: ["headphone"]))
        #expect(audio.sessions.last { $0.group.bundleID == "test.browser" }?.playbackUIDs == ["headphone"])
        #expect(model.shutdown())
    }

    @Test func leavingAndReenteringMultiOutputRestoresSavedCustomRoute() throws {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let browser = applicationRow(bundleID: "test.browser", name: "Google Chrome", objectID: 43)
        audio.additionalRows = [browser]
        let suite = "Aural.RouteIntegration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment,
                             appAudioRouteStore: AppAudioRouteStore(defaults: defaults))

        #expect(model.startSimultaneousOutput(["speaker", "headphone"]))
        model.setApplicationAudioRoute(.custom(deviceUIDs: ["speaker"]), for: browser.id)
        #expect(model.effectiveApplicationAudioRoute(for: browser.id) == .custom(deviceUIDs: ["speaker"]))

        model.stopSimultaneousOutput()
        #expect(!model.applicationAudioRoutingEnabled)
        #expect(model.applicationAudioRoute(for: browser.id) == .custom(deviceUIDs: ["speaker"]))
        #expect(model.sessions.isEmpty)

        #expect(model.startSimultaneousOutput(["speaker", "headphone"]))
        #expect(model.effectiveApplicationAudioRoute(for: browser.id) == .custom(deviceUIDs: ["speaker"]))
        #expect(audio.sessions.last { $0.group.bundleID == "test.browser" }?.playbackUIDs == ["speaker"])
        #expect(model.shutdown())
    }

    @Test func savedRouteRestoresForTheSameBundleAfterModelRestart() throws {
        let suite = "Aural.RouteIntegration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let firstHardware = RoutingTestHardware()
        let firstAudio = SessionFixture()
        let firstBrowser = applicationRow(bundleID: "test.browser", name: "Google Chrome", objectID: 43)
        firstAudio.additionalRows = [firstBrowser]
        let firstModel = AppModel(outputHardware: firstHardware.hardware, startsMonitoring: false,
                                  applicationAudio: firstAudio.environment,
                                  appAudioRouteStore: AppAudioRouteStore(defaults: defaults))
        #expect(firstModel.startSimultaneousOutput(["speaker", "headphone"]))
        firstModel.setApplicationAudioRoute(.custom(deviceUIDs: ["speaker"]), for: firstBrowser.id)
        #expect(firstModel.shutdown())

        // 新模型模拟应用重启：只凭稳定 bundle 身份恢复设备 UID 路由。
        let secondHardware = RoutingTestHardware()
        let secondAudio = SessionFixture()
        let secondBrowser = applicationRow(bundleID: "test.browser", name: "Google Chrome", objectID: 143)
        secondAudio.additionalRows = [secondBrowser]
        let secondModel = AppModel(outputHardware: secondHardware.hardware, startsMonitoring: false,
                                   applicationAudio: secondAudio.environment,
                                   appAudioRouteStore: AppAudioRouteStore(defaults: defaults))
        #expect(secondModel.startSimultaneousOutput(["speaker", "headphone"]))
        #expect(secondModel.effectiveApplicationAudioRoute(for: secondBrowser.id)
                == .custom(deviceUIDs: ["speaker"]))
        #expect(secondAudio.sessions.last { $0.group.bundleID == "test.browser" }?.playbackUIDs == ["speaker"])
        #expect(secondModel.shutdown())
    }

    @Test func deniedPermissionDisablesAppControlsWithoutStartingSilentSessions() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        audio.captureAccess = .denied
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment)
        model.setMeteringVisible(true, for: .popover)
        model.setApplicationGain(0.2, for: audio.row.id)
        model.toggleApplicationMute(audio.row.id)
        model.applyApplication(audio.row.id)
        #expect(model.audioCaptureAccess == .denied)
        #expect(model.sessions.isEmpty && audio.sessions.isEmpty)
        #expect(model.mixStates[audio.row.id]?.gain == 1)
        #expect(model.mixStates[audio.row.id]?.muted == false)
        #expect(model.mixStates[audio.row.id]?.failure == nil)
        #expect(model.operationError == nil)
        #expect(model.audio != nil && model.audioError == nil)
        #expect(model.shutdown())
    }

    @Test func permissionRevocationStopsProcessingButKeepsGainAndRouteIntent() throws {
        let suite = "Aural.RouteIntegration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment,
                             appAudioRouteStore: AppAudioRouteStore(defaults: defaults))
        model.setMeteringVisible(true, for: .popover)
        model.setApplicationGain(0.35, for: audio.row.id)
        #expect(model.startSimultaneousOutput(["speaker", "headphone"]))
        model.setApplicationAudioRoute(.custom(deviceUIDs: ["speaker"]), for: audio.row.id)
        #expect(audio.sessions.last?.isActive == true)

        audio.captureAccess = .denied
        model.refresh()
        #expect(model.sessions.isEmpty)
        #expect(audio.sessions.allSatisfy { $0.isReleased })
        #expect(model.levelSource(for: audio.row.id).level == nil)
        #expect(model.mixStates[audio.row.id]?.gain == 0.35)
        #expect(model.applicationAudioRoute(for: audio.row.id) == .custom(deviceUIDs: ["speaker"]))
        #expect(model.mixStates[audio.row.id]?.failure == nil)
        #expect(model.operationError == nil)
        // 权限只影响应用处理，不退出用户已经确认的多设备输出组。
        #expect(model.outputRouting.isSimultaneous)

        audio.captureAccess = .authorized
        model.refresh()
        #expect(model.audioCaptureAccess == .authorized)
        #expect(audio.sessions.last?.isActive == true)
        #expect(audio.sessions.last?.gain == 0.35)
        #expect(audio.sessions.last?.playbackUIDs == ["speaker"])
        #expect(model.shutdown())
    }

    @Test func reopeningThePanelChecksPermissionBeforeCreatingAMeter() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment)
        audio.captureAccess = .denied
        model.setMeteringVisible(true, for: .popover)
        #expect(model.audioCaptureAccess == .denied)
        #expect(audio.sessions.isEmpty)
        #expect(model.shutdown())
    }

    @Test func gainingPermissionRestartsReadOnlyMetersWithoutManagingVolume() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        audio.captureAccess = .notDetermined
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment)
        model.setMeteringVisible(true, for: .popover)
        #expect(model.sessions.isEmpty)
        audio.captureAccess = .authorized
        model.refresh()
        #expect(audio.sessions.last?.mode == .metering)
        #expect(audio.sessions.last?.isActive == true)
        #expect(model.mixStates[audio.row.id]?.managed == false)
        #expect(model.shutdown())
    }

    @Test func unavailablePermissionQueryDoesNotPretendAuthorizedOrDenied() {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        audio.captureAccess = .unavailable
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment)
        model.setMeteringVisible(true, for: .popover)
        #expect(model.audioCaptureAccess == .unavailable)
        #expect(model.sessions.isEmpty)
        #expect(model.shutdown())
    }

    private func applicationRow(bundleID: String, name: String, objectID: AudioObjectID) -> ApplicationAudioRow {
        let id = "bundle:\(bundleID)"
        let group = AudioProcessGroup(id: id, bundleID: bundleID,
                                      processIDs: [Int32(objectID)], objectIDs: [objectID])
        return ApplicationAudioRow(id: id, bundleID: bundleID, name: name,
                                   applicationURL: nil, group: group, isRunningOutput: true)
    }
}

@MainActor
private final class SessionFixture {
    var playing = true
    var captureAccess: SystemAudioCaptureAccess = .authorized
    var omitsApplication = false
    var additionalRows: [ApplicationAudioRow] = []
    var routePending = false
    var startError: Error?
    var healthError: Error?
    var readError: Error?
    var now = Date(timeIntervalSince1970: 1_000)
    var sessions: [MemoryAudioSession] = []
    var row: ApplicationAudioRow {
        let records = [AudioProcessRecord(objectID: 42, processID: 12, bundleID: "test.music", isRunningOutput: playing)]
        let app = RunningApplicationInfo(processID: 12, bundleID: "test.music", name: "测试音乐", bundleURL: nil)
        return ApplicationCatalog.rows(applications: [app], records: records, executableURLs: [:])[0]
    }
    var environment: ApplicationAudioEnvironment {
        ApplicationAudioEnvironment(readApplications: { _ in
            if let readError = self.readError { throw readError }
            let rows = (self.omitsApplication ? [] : [self.row]) + self.additionalRows
            return (rows, rows.count)
        }, hasMixerConflict: { false },
            makeSession: { group, output, route, mode in
                let session = MemoryAudioSession(group: group, output: output, route: route, mode: mode)
                session.startFailure = { self.routePending ? ApplicationRoutePending() : self.startError }
                session.healthFailure = { self.healthError }
                self.sessions.append(session)
                return session
            }, now: { self.now }, captureAccess: { self.captureAccess })
    }
}

@MainActor
private final class MemoryAudioSession: ApplicationAudioSession {
    let group: AudioProcessGroup
    let output: AudioOutput
    let mode: ApplicationAudioMode
    let playbackRoute: ApplicationPlaybackRoute
    let playbackUIDs: [String]
    var isActive = false
    var isReleased = true
    var gain: Float = 1
    var muted = false
    var failStop = false
    var startFailure: () -> Error? = { nil }
    var healthFailure: () -> Error? = { nil }
    init(group: AudioProcessGroup, output: AudioOutput, route: ApplicationPlaybackRoute?, mode: ApplicationAudioMode) {
        self.group = group; self.output = output; self.mode = mode
        playbackRoute = route ?? .single(output)
        playbackUIDs = playbackRoute.playbackDeviceUIDs
    }
    func setGain(_ value: Float) throws { gain = value }
    func setMuted(_ value: Bool) { muted = value }
    func start() throws {
        if let error = startFailure() { throw error }
        isActive = true; isReleased = false
    }
    func checkHealth(expectingAudio: Bool) throws {
        if let error = healthFailure() { throw error }
    }
    func stop() throws {
        if failStop { throw AudioFailure("注入：旧会话释放失败") }
        isActive = false; isReleased = true
    }
    // 模拟会话不生成虚构电平，验收只检查目标和生命周期，不将它当真实发声证据。
    func consumePeak() -> Float? { nil }
}
