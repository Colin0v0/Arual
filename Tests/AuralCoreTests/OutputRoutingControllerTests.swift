import CoreAudio
import Foundation
import Testing
@testable import AuralCore

@MainActor
struct OutputRoutingControllerTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test func selectingAlreadyConfirmedRouteDoesNotStopSessionsOrRebuildResources() {
        for intent: OutputRoutingIntent in [.single("speaker"), .simultaneous(["speaker", "headphone"])] {
            let fixture = RoutingTestHardware()
            let controller = OutputRoutingController(hardware: fixture.hardware)
            controller.request(intent, at: start)
            let writes = fixture.selections.count
            let created = fixture.created.count
            let destroyed = fixture.destroyed.count
            controller.beforeChanging = { Issue.record("重复选择已生效路由不能停止音频会话") }
            controller.request(intent, at: start.addingTimeInterval(1))
            #expect(controller.state.phase == .confirmed)
            #expect(fixture.selections.count == writes)
            #expect(fixture.created.count == created)
            #expect(fixture.destroyed.count == destroyed)
        }
    }

    @Test func channelLossDuringCreationContinuesOnRemainingMembersInsteadOfLatchingFailure() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        fixture.afterCreate = { _ in fixture.offline.insert(2) }
        controller.request(.simultaneous(["speaker", "headphone", "usb"]), at: start)
        #expect(controller.state.phase == .confirmed)
        #expect(controller.state.error == nil)
        #expect(controller.state.selectedMemberUIDs == ["speaker", "headphone", "usb"])
        #expect(controller.state.confirmed?.aggregate?.outputs.map(\.uid) == ["speaker", "usb"])
        #expect(controller.state.pendingCleanup.isEmpty)
        #expect(fixture.created.count == 2)
        #expect(fixture.destroyed.count == 1)
    }

    @Test func channelLossAfterDefaultWriteButBeforeActivationConfirmationContinuesPlayback() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        fixture.afterSelection = { deviceID in
            if deviceID >= 100 { fixture.offline.insert(2) }
        }
        controller.request(.simultaneous(["speaker", "headphone", "usb"]), at: start)
        #expect(controller.state.phase == .confirmed)
        #expect(controller.state.error == nil && controller.state.warning == nil)
        #expect(controller.state.confirmed?.aggregate?.outputs.map(\.uid) == ["speaker", "usb"])
        #expect(controller.state.pendingCleanup.isEmpty)
        #expect(fixture.destroyed.count == 1)
    }

    @Test func aliveButInactiveMemberDoesNotCauseRepeatedRebuildsWithoutRecoveryEvidence() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        fixture.inactive.insert("headphone")
        controller.request(.simultaneous(["speaker", "headphone", "usb"]), at: start)
        #expect(controller.state.phase == .confirmed)
        #expect(controller.state.confirmed?.aggregate?.outputs.map(\.uid) == ["speaker", "usb"])
        let created = fixture.created.count
        for cycle in 1...10 {
            controller.observe(fixture.snapshot, at: start.addingTimeInterval(Double(cycle)))
            #expect(fixture.created.count == created)
            #expect(controller.state.error == nil)
        }
        fixture.inactive.remove("headphone")
        fixture.worn[2] = true
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(11))
        #expect(fixture.created.count == created)
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(11.6))
        #expect(controller.state.confirmed?.aggregate?.outputs.map(\.uid) == ["speaker", "headphone", "usb"])
        #expect(controller.state.unavailableMemberUIDs.isEmpty)
    }

    @Test func explicitOutOfEarStateExcludesAliveHeadphoneAndRestoresItOnlyAfterStableWear() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.simultaneous(["speaker", "headphone", "usb"]), at: start)
        fixture.worn[2] = false
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(1))
        #expect(controller.state.confirmed?.aggregate?.outputs.map(\.uid) == ["speaker", "usb"])
        fixture.worn[2] = true
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(2))
        #expect(controller.state.unavailableMemberUIDs == ["headphone"])
        fixture.worn[2] = false
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(2.2))
        fixture.worn[2] = true
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(3))
        #expect(controller.state.unavailableMemberUIDs == ["headphone"])
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(3.6))
        #expect(controller.state.confirmed?.aggregate?.outputs.map(\.uid) == ["speaker", "headphone", "usb"])
        #expect(controller.state.error == nil && controller.state.warning == nil)
    }

    @Test func repeatedEarRemovalKeepsTwoOtherMembersAndNeverChoosesAnUnselectedDevice() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        let selected = ["speaker", "headphone", "usb"]
        controller.request(.simultaneous(selected), at: start)
        for cycle in 0..<20 {
            let now = start.addingTimeInterval(Double(cycle) * 10 + 1)
            fixture.offline.insert(2)
            // 系统摘耳通知与默认输出变化可以先后到达，不能计入“反复抢占”。
            fixture.selected = 2
            fixture.systemSelected = 2
            controller.observe(fixture.snapshot, at: now)
            #expect(controller.state.phase == .confirmed)
            #expect(controller.state.confirmed?.aggregate?.outputs.map(\.uid) == ["speaker", "usb"])
            #expect(controller.state.selectedMemberUIDs == selected)
            #expect(controller.state.unavailableMemberUIDs == ["headphone"])
            #expect(controller.state.error == nil && controller.state.warning == nil)
            #expect(controller.state.pendingCleanup.isEmpty)
            fixture.offline.remove(2)
            controller.observe(fixture.snapshot, at: now.addingTimeInterval(1))
            controller.observe(fixture.snapshot, at: now.addingTimeInterval(1.6))
            #expect(controller.state.confirmed?.aggregate?.outputs.map(\.uid) == selected)
            #expect(controller.state.unavailableMemberUIDs.isEmpty)
        }
    }

    @Test func noAvailableSelectedMemberWaitsWithoutChoosingTheUnselectedSpeaker() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.simultaneous(["headphone", "usb"]), at: start)
        fixture.offline = [2, 3]
        let writes = fixture.selections.count
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(1))
        #expect(controller.state.phase == .awaitingMembers)
        #expect(controller.state.confirmed == nil)
        #expect(controller.state.selectedMemberUIDs == ["headphone", "usb"])
        #expect(controller.state.pendingCleanup.isEmpty)
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(60))
        #expect(fixture.selections.count == writes)
        #expect(controller.state.error == nil)
        fixture.offline.remove(3)
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(61))
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(61.6))
        #expect(controller.state.phase == .confirmed)
        #expect(controller.state.confirmed?.output.uid == "usb")
        #expect(!fixture.selections.contains(1))
    }

    @Test func cancellingUnavailableMemberPreventsItFromBeingAutomaticallyAddedBack() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.simultaneous(["speaker", "headphone", "usb"]), at: start)
        fixture.offline.insert(2)
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(1))
        controller.request(.simultaneous(["speaker", "usb"]), at: start.addingTimeInterval(2))
        let created = fixture.created.count
        fixture.offline.remove(2)
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(3))
        #expect(controller.state.selectedMemberUIDs == ["speaker", "usb"])
        #expect(controller.state.confirmed?.aggregate?.outputs.map(\.uid) == ["speaker", "usb"])
        #expect(fixture.created.count == created)
    }

    @Test func vanishedEarphoneRejoinsWithItsNewHandleWithoutLosingItsCheckbox() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.simultaneous(["speaker", "headphone", "usb"]), at: start)
        fixture.outputs.removeAll { $0.uid == "headphone" }
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(1))
        #expect(controller.state.confirmed?.aggregate?.outputs.map(\.uid) == ["speaker", "usb"])
        #expect(controller.state.configuredOutputs.map(\.uid) == ["speaker", "headphone", "usb"])
        #expect(controller.state.selectedMemberUIDs.contains("headphone"))
        fixture.outputs.append(AudioOutput(id: 22, uid: "headphone", name: "测试耳机",
                                          transport: kAudioDeviceTransportTypeBluetooth))
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(2))
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(2.6))
        #expect(controller.state.confirmed?.aggregate?.outputs.first { $0.uid == "headphone" }?.id == 22)
        #expect(controller.state.unavailableMemberUIDs.isEmpty)
        #expect(controller.state.pendingCleanup.isEmpty)
    }

    @Test func losingClockMemberRebuildsUsingOnlyTheOtherSelectedDevices() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.simultaneous(["speaker", "headphone", "usb"]), at: start)
        #expect(controller.state.confirmed?.aggregate?.mainOutputUID == "speaker")
        fixture.offline.insert(1)
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(1))
        #expect(controller.state.phase == .confirmed)
        #expect(controller.state.confirmed?.aggregate?.outputs.map(\.uid) == ["headphone", "usb"])
        #expect(controller.state.confirmed?.aggregate?.mainOutputUID == "usb")
        #expect(controller.state.unavailableMemberUIDs == ["speaker"])
        #expect(controller.state.error == nil)
    }

    @Test func staleNameAfterDestroyWaitsAndCompletesWithoutRepeatingDestroy() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.simultaneous(["speaker", "headphone"]), at: start)
        let oldGroup = fixture.selected
        fixture.afterDestroy = { _ in fixture.pendingSnapshot = true }

        controller.request(.simultaneous(["headphone", "usb"]), at: start.addingTimeInterval(1))
        #expect(controller.state.phase == .awaitingHAL)
        #expect(controller.state.error == nil)
        #expect(controller.retainedRoute?.deviceID == oldGroup)
        #expect(fixture.destroyed == [oldGroup])

        fixture.pendingSnapshot = false
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(1.2))
        #expect(controller.state.phase == .confirmed)
        #expect(controller.state.selectedMemberUIDs == ["headphone", "usb"])
        #expect(controller.state.error == nil)
        #expect(controller.state.pendingCleanup.isEmpty)
        #expect(fixture.destroyed == [oldGroup])
    }

    @Test func pendingSnapshotDoesNotExtendReleaseDeadlineOrHideOtherErrors() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.simultaneous(["speaker", "headphone"]), at: start)
        fixture.keepAfterDestroy = true
        fixture.afterDestroy = { _ in fixture.pendingSnapshot = true }
        controller.request(.single("headphone"), at: start.addingTimeInterval(1))
        let pending = AudioSnapshotPending(AudioFailure("读取音频名称失败", status: HAL.badObjectStatus))
        #expect(controller.deferPendingObservation(pending, at: start.addingTimeInterval(2)))
        #expect(!controller.deferPendingObservation(AudioFailure("权限错误"), at: start.addingTimeInterval(2)))
        #expect(!controller.deferPendingObservation(pending, at: start.addingTimeInterval(4)))
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(4))
        #expect(controller.state.phase == .failed)
        #expect(controller.state.error != nil)
        #expect(controller.retainedRoute != nil)
        #expect(fixture.destroyed.count == 1)
    }

    @Test func oneTwoOneTwoKeepsBothPossibleSingleMembers() {
        for retained in ["speaker", "headphone"] {
            let fixture = RoutingTestHardware()
            let controller = OutputRoutingController(hardware: fixture.hardware)
            controller.observe(fixture.snapshot)
            for intent: OutputRoutingIntent in [.simultaneous([retained]), .simultaneous(["speaker", "headphone"]),
                                                .simultaneous([retained]), .simultaneous(["speaker", "headphone"])] {
                controller.request(intent)
                #expect(controller.state.phase == .confirmed)
                #expect(controller.state.confirmed?.intent == intent)
                #expect(controller.state.actualOutput?.id == fixture.selected)
                #expect(fixture.selected == fixture.systemSelected)
                #expect(controller.state.pendingCleanup.isEmpty)
            }
            #expect(fixture.created.count == 2)
            #expect(fixture.destroyed.count == 1)
        }
    }

    @Test func writeIsNotConfirmationAndBothDefaultsMustAgree() {
        let fixture = RoutingTestHardware()
        fixture.deferSystemSelection = true
        let controller = OutputRoutingController(hardware: fixture.hardware)
        var phases: [OutputRoutingPhase] = []
        controller.didChange = { phases.append($0.phase) }
        controller.request(.simultaneous(["speaker", "headphone"]), at: start)
        #expect(controller.state.phase == .awaitingHAL)
        #expect(controller.state.confirmed == nil)
        #expect(phases.contains(.switching))
        let writes = fixture.selections.count
        #expect(writes == 2) // 首次写入只落实媒体，内部观察再补写一次提示音。
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(2))
        // 已经补写过的缺口不能继续循环重试。
        #expect(fixture.selections.count == writes)
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(2.1))
        #expect(fixture.selections.count == writes)
        fixture.commitSelection()
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(2.5))
        #expect(controller.state.phase == .confirmed)
    }

    @Test func confirmationTimeoutReportsActualAndRetainedResourceWithoutRetryingWrite() {
        let fixture = RoutingTestHardware()
        fixture.deferSelection = true
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.simultaneous(["speaker", "headphone"]), at: start)
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(4))
        #expect(controller.state.phase == .failed)
        #expect(controller.state.confirmed == nil)
        #expect(controller.state.actualOutput?.uid == "speaker")
        #expect(controller.state.pendingCleanup.count == 1)
        #expect(fixture.selections.count == 1)
        #expect(fixture.destroyed.isEmpty)
        fixture.commitSelection()
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(5))
        #expect(controller.state.phase == .failed) // 迟到确认不能暗中解除失败。
    }

    @Test func secondCreationFailureDoesNotRestoreImaginaryOldMembers() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.simultaneous(["speaker", "headphone"]))
        fixture.failCreation = true
        controller.request(.simultaneous(["headphone", "usb"]))
        #expect(controller.state.phase == .failed)
        #expect(controller.state.confirmed == nil)
        #expect(controller.state.actualOutput?.uid == "headphone")
        #expect(controller.state.selectedMemberUIDs.isEmpty)
        #expect(controller.state.pendingCleanup.isEmpty)
        #expect(controller.state.completedSteps.contains("已释放旧组合"))
        #expect(fixture.compositions.isEmpty)
    }

    @Test func failedReleaseReportsRealSingleOutputAndRequiresExplicitRetry() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.simultaneous(["speaker", "headphone"]))
        fixture.failDestroy = true
        controller.request(.simultaneous(["headphone"]))
        #expect(controller.state.phase == .failed)
        #expect(controller.state.actualOutput?.uid == "headphone")
        #expect(controller.state.confirmed == nil)
        #expect(controller.state.pendingCleanup.count == 1)
        let writes = fixture.selections.count
        controller.observe(fixture.snapshot)
        #expect(fixture.selections.count == writes)
        fixture.failDestroy = false
        controller.request(.simultaneous(["headphone"]))
        #expect(controller.state.phase == .confirmed)
        #expect(controller.state.selectedMemberUIDs == ["headphone"])
        #expect(controller.state.pendingCleanup.isEmpty)
    }

    @Test func destroySuccessWaitsForAbsenceAndOnlyFailsAfterItsDeadline() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.simultaneous(["speaker", "headphone"]), at: start)
        fixture.keepAfterDestroy = true
        controller.request(.simultaneous(["speaker"]), at: start)
        #expect(controller.state.phase == .awaitingHAL)
        #expect(controller.state.error == nil)
        #expect(controller.state.confirmed == nil)
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(4))
        #expect(controller.state.phase == .failed)
        #expect(controller.state.pendingCleanup.count == 1)
        #expect(fixture.destroyed.count == 1)
        // 超时后资源事实仍可更新，但不能因此偷偷重新执行已失败的输出请求。
        fixture.compositions.removeAll()
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(5))
        #expect(controller.state.phase == .failed)
        #expect(controller.state.pendingCleanup.isEmpty)
        #expect(controller.retainedRoute == nil)
    }

    @Test func delayedAggregateRemovalFinishesTheSameSelectionWithoutRetryingDestroy() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.simultaneous(["speaker", "headphone"]), at: start)
        let oldID = fixture.selected
        fixture.keepAfterDestroy = true
        controller.request(.single("headphone"), at: start)
        for delay in [0.01, 0.02, 0.03] {
            controller.observe(fixture.snapshot, at: start.addingTimeInterval(delay))
            #expect(controller.state.phase == .awaitingHAL)
            #expect(controller.state.error == nil)
            #expect(fixture.destroyed == [oldID])
        }
        fixture.compositions.removeValue(forKey: oldID)
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(0.04))
        #expect(controller.state.phase == .confirmed)
        #expect(controller.state.confirmed?.output.uid == "headphone")
        #expect(controller.state.pendingCleanup.isEmpty)
        #expect(!controller.hasPendingRelease)
        #expect(fixture.destroyed == [oldID])
    }

    @Test func delayedUnmanagedRemovalWaitsBeforeActivatingTheNewOutput() throws {
        let fixture = RoutingTestHardware()
        let plan = try MultiOutputPlan(outputs: Array(fixture.outputs.prefix(2)),
                                       sampleRates: ["speaker": 48_000, "headphone": 48_000])
        fixture.compositions[88] = plan.description(uid: "local.aural.multi.pending-old")
        fixture.keepAfterDestroy = true
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.single("headphone"), at: start)
        #expect(controller.state.phase == .awaitingHAL)
        #expect(controller.state.error == nil)
        #expect(fixture.selections.isEmpty)
        fixture.compositions.removeValue(forKey: 88)
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(0.04))
        #expect(controller.state.phase == .confirmed)
        #expect(controller.state.confirmed?.output.uid == "headphone")
        #expect(!controller.hasPendingRelease)
        #expect(fixture.destroyed == [88])
    }

    @Test func externalCleanupDelayDoesNotTurnANormalMediaSwitchIntoAnError() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.simultaneous(["speaker", "headphone"]), at: start)
        let old = fixture.selected
        fixture.keepAfterDestroy = true
        fixture.selected = 2; fixture.systemSelected = 1
        controller.observe(fixture.snapshot, at: start)
        #expect(controller.state.phase == .stable)
        #expect(controller.state.error == nil)
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(0.02))
        #expect(fixture.destroyed == [old])
        fixture.compositions.removeValue(forKey: old)
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(0.04))
        #expect(controller.state.confirmed?.output.uid == "headphone")
        #expect(controller.state.error == nil)
        #expect(controller.state.pendingCleanup.isEmpty)
    }

    @Test func externalBluetoothSelectionIsAdoptedWithoutRewritingEitherDefault() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.simultaneous(["speaker", "headphone"]))
        let writes = fixture.selections.count
        fixture.selected = 2; fixture.systemSelected = 1
        controller.observe(fixture.snapshot)
        #expect(fixture.selections.count == writes)
        #expect(controller.state.phase == .stable)
        #expect(controller.state.error == nil)
        #expect(controller.state.confirmed?.output.uid == "headphone")
        #expect(controller.state.actualSystemOutputID == 1)
        #expect(controller.state.pendingCleanup.isEmpty)
        #expect(fixture.compositions.isEmpty)
        #expect(controller.latestSnapshot?.outputs.contains(where: { $0.isAuralMultiOutput }) == false)
    }

    @Test func externalMediaChangeReunifiesSoundEffectsAndReleasesOwnedAggregate() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.simultaneous(["speaker", "headphone"]))
        let group = fixture.selected
        fixture.selected = 2 // 媒体已经离开组合，但提示音仍指向 Aural 自有组合。
        let writes = fixture.selections.count
        controller.observe(fixture.snapshot)
        #expect(controller.state.confirmed?.output.uid == "headphone")
        #expect(controller.state.phase == .confirmed)
        #expect(controller.state.error == nil)
        #expect(fixture.systemSelected == 2)
        #expect(fixture.destroyed == [group])
        #expect(controller.state.pendingCleanup.isEmpty)
        #expect(fixture.selections.count == writes + 1)
    }

    @Test func removedHeadphoneKeepsRemainingSelectionPlayingAndRejoinsWhenAvailable() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.simultaneous(["speaker", "headphone"]), at: start)
        fixture.offline.insert(2)
        // 摘耳后只让暂不可用的成员退出实际路由，扬声器继续，不清空原始勾选。
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(0.2))
        #expect(controller.state.phase == .confirmed)
        #expect(controller.state.error == nil)
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(3.5))
        #expect(controller.state.phase == .confirmed)
        #expect(controller.state.confirmed?.output.uid == "speaker")
        #expect(controller.state.selectedMemberUIDs == ["speaker", "headphone"])
        #expect(controller.state.unavailableMemberUIDs == ["headphone"])
        #expect(controller.state.warning == nil)
        #expect(controller.state.pendingCleanup.isEmpty)
        fixture.offline.remove(2)
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(3.6))
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(4.2))
        #expect(controller.state.phase == .confirmed)
        #expect(controller.state.confirmed?.aggregate?.outputs.map(\.uid) == ["speaker", "headphone"])
        #expect(controller.state.unavailableMemberUIDs.isEmpty)
        #expect(fixture.created.count == 2)
    }

    @Test func rapidRequestsAreSerializedAndOnlyTheLastQueuedIntentRuns() {
        let fixture = RoutingTestHardware()
        fixture.deferSelection = true
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.simultaneous(["speaker", "headphone"]), at: start)
        controller.request(.simultaneous(["headphone"]), at: start)
        controller.request(.simultaneous(["speaker"]), at: start)
        #expect(controller.state.queued == .simultaneous(["speaker"]))
        #expect(fixture.created.count == 1)
        fixture.deferSelection = false
        fixture.commitSelection()
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(1))
        #expect(controller.state.phase == .confirmed)
        #expect(controller.state.confirmed?.intent == .simultaneous(["speaker"]))
        #expect(controller.state.queued == nil)
        #expect(fixture.compositions.isEmpty)
    }

    @Test func startupReunifiesMediaAndSoundEffectsAwayFromUnmanagedAggregate() throws {
        let fixture = RoutingTestHardware()
        let plan = try MultiOutputPlan(outputs: Array(fixture.outputs.prefix(2)),
                                       sampleRates: ["speaker": 48_000, "headphone": 48_000])
        fixture.compositions[88] = plan.description(uid: "local.aural.multi.previous")
        fixture.systemSelected = 88
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.observe(fixture.snapshot)
        #expect(controller.state.phase == .confirmed)
        #expect(controller.state.error == nil)
        #expect(controller.state.confirmed?.output.uid == "speaker")
        #expect(fixture.selected == 1 && fixture.systemSelected == 1)
        #expect(fixture.destroyed == [88])
        #expect(controller.state.pendingCleanup.isEmpty)
    }

    @Test func earRemovalAndSystemDefaultChangeDoNotAdoptTheUnavailableHeadphone() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.simultaneous(["speaker", "headphone"]), at: start)
        fixture.selected = 2
        fixture.offline.insert(2)
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(0.2))
        #expect(controller.state.phase == .confirmed)
        #expect(controller.state.error == nil)
        fixture.offline.remove(2)
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(0.5))
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(1.1))
        #expect(controller.state.phase == .confirmed)
        #expect(controller.state.confirmed?.aggregate?.outputs.map(\.uid) == ["speaker", "headphone"])
        #expect(fixture.systemSelected == fixture.selected)
        #expect(controller.state.warning == nil)
        #expect(controller.state.pendingCleanup.isEmpty)
    }

    @Test func defaultPreemptionWithActivePlaybackOnConfirmedRouteIsRestoredWithoutStoppingSessions() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.single("speaker"))
        var sessionStops = 0
        controller.beforeChanging = { sessionStops += 1 }
        let writes = fixture.selections.count

        // Apple 只抢默认输出，真实播放进程仍在扬声器上。
        fixture.selected = 2
        fixture.systemSelected = 2
        fixture.activePlayback = [1]
        controller.observe(fixture.snapshot)
        #expect(fixture.selected == 1 && fixture.systemSelected == 1)
        #expect(fixture.selections.count == writes + 1)
        #expect(sessionStops == 0)
        #expect(controller.state.confirmed?.output.uid == "speaker")
        #expect(controller.state.actualOutput?.uid == "speaker")
        #expect(controller.state.error == nil)
    }

    @Test func aggregatePreemptionIsRestoredWhenActiveProcessStillUsesOneOfItsMembers() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.simultaneous(["speaker", "headphone"]))
        let aggregateID = fixture.selected
        controller.beforeChanging = { Issue.record("真实播放未离开组合时不能停止会话") }
        let writes = fixture.selections.count

        fixture.selected = 3
        fixture.systemSelected = 3
        fixture.activePlayback = [2]
        controller.observe(fixture.snapshot)
        #expect(fixture.selected == aggregateID && fixture.systemSelected == aggregateID)
        #expect(fixture.selections.count == writes + 1)
        #expect(fixture.destroyed.isEmpty)
        #expect(controller.state.confirmed?.aggregate?.deviceID == aggregateID)
        #expect(controller.state.error == nil)
    }

    @Test func realPlaybackMoveAwayFromConfirmedRouteIsStillAdopted() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.single("speaker"))
        var sessionStops = 0
        controller.beforeChanging = { sessionStops += 1 }

        fixture.selected = 2
        fixture.systemSelected = 2
        fixture.activePlayback = [2]
        controller.observe(fixture.snapshot)
        #expect(sessionStops == 1)
        #expect(controller.state.confirmed?.output.uid == "headphone")
        #expect(controller.state.actualOutput?.uid == "headphone")
        #expect(controller.state.error == nil)
    }

    @Test func oneActiveProcessRemainingOnConfirmedRoutePreventsTeardown() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.single("speaker"))
        controller.beforeChanging = { Issue.record("真实播放仍在原路由时不能停止会话") }
        let writes = fixture.selections.count

        // 两个应用分别播放：一个仍在扬声器，另一个已经跟随新的默认输出。
        fixture.selected = 2
        fixture.systemSelected = 2
        fixture.activePlayback = [1, 2]
        controller.observe(fixture.snapshot)
        #expect(fixture.selected == 1 && fixture.systemSelected == 1)
        #expect(fixture.selections.count == writes + 1)
        #expect(controller.state.confirmed?.output.uid == "speaker")
        #expect(controller.state.error == nil)
    }

    @Test func activeManagedSessionOnConfirmedRouteAlsoPreventsTeardown() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.single("speaker"))
        controller.beforeChanging = { Issue.record("Aural 会话仍在原路由重放时不能停止会话") }
        // APP 接管后源进程可能已跟随默认输出，但本进程仍在原路由重放。
        controller.localPlaybackOnConfirmedRoute = { true }
        let writes = fixture.selections.count

        fixture.selected = 2
        fixture.systemSelected = 2
        fixture.activePlayback = []
        controller.observe(fixture.snapshot)
        #expect(fixture.selected == 1 && fixture.systemSelected == 1)
        #expect(fixture.selections.count == writes + 1)
        #expect(controller.state.confirmed?.output.uid == "speaker")
        #expect(controller.state.error == nil)
    }

    @Test func secondFastTakeoverYieldsToRealOutputWithoutBecomingAFailure() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.single("speaker"), at: start)
        var sessionStops = 0
        controller.beforeChanging = { sessionStops += 1 }

        fixture.selected = 2
        fixture.systemSelected = 2
        fixture.activePlayback = [1]
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(0.2))
        #expect(controller.state.confirmed?.output.uid == "speaker")
        let writes = fixture.selections.count

        // 默认输出恢复后仍要记住这次抢占；否则下一次抢占会被当成第一次而无限来回切。
        fixture.selected = 1
        fixture.systemSelected = 1
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(0.6))

        // AirPods 智能路由会在数秒后再次抢占；不能继续来回切，也不能留下残留组合。
        fixture.selected = 2
        fixture.systemSelected = 2
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(4.6))
        #expect(sessionStops == 1)
        #expect(fixture.selections.count == writes)
        #expect(controller.state.confirmed?.output.uid == "headphone")
        #expect(controller.state.phase == .stable)
        #expect(controller.state.error == nil)
        #expect(controller.state.warning != nil)
        #expect(controller.state.pendingCleanup.isEmpty)

        // 提示针对刚刚跟随的耳机保留；用户主动换到另一台真实设备后消失。
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(5.5))
        #expect(controller.state.warning != nil)
        fixture.selected = 3
        fixture.systemSelected = 3
        fixture.activePlayback = []
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(6))
        #expect(controller.state.confirmed?.output.uid == "usb")
        #expect(controller.state.warning == nil)
    }

    @Test func takeoverAfterThirtySecondsIsRestoredAgain() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.single("speaker"), at: start)
        controller.beforeChanging = { Issue.record("恢复默认输出时不能停止会话") }

        fixture.selected = 2
        fixture.systemSelected = 2
        fixture.activePlayback = [1]
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(0.2))
        #expect(fixture.selected == 1)
        let writes = fixture.selections.count

        fixture.selected = 2
        fixture.systemSelected = 2
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(30.5))
        #expect(fixture.selected == 1 && fixture.systemSelected == 1)
        #expect(fixture.selections.count == writes + 1)
        #expect(controller.state.confirmed?.output.uid == "speaker")
    }

    @Test func fastTakeoverWithANewHALHandleIsStillRecognizedByUID() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.single("speaker"), at: start)
        controller.beforeChanging = { }

        fixture.selected = 2
        fixture.systemSelected = 2
        fixture.activePlayback = [1]
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(0.2))
        #expect(controller.state.confirmed?.output.uid == "speaker")

        // 整批设备换号后，同一副耳机仍是同一台物理设备。
        fixture.outputs = [
            AudioOutput(id: 11, uid: "speaker", name: "测试扬声器", transport: kAudioDeviceTransportTypeBuiltIn),
            AudioOutput(id: 12, uid: "headphone", name: "测试耳机", transport: kAudioDeviceTransportTypeBluetooth)
        ]
        fixture.selected = 12
        fixture.systemSelected = 12
        fixture.activePlayback = [11]
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(4.6))

        #expect(controller.state.confirmed?.output.uid == "headphone")
        #expect(controller.state.warning != nil)
        #expect(controller.state.error == nil)
    }

    @Test func bluetoothReconnectWithANewDeviceIDKeepsConfirmedRoute() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.single("headphone"))
        let writes = fixture.selections.count

        fixture.outputs[1] = AudioOutput(id: 22, uid: "headphone", name: "测试耳机",
                                         transport: kAudioDeviceTransportTypeBluetooth)
        fixture.selected = 22
        fixture.systemSelected = 22
        fixture.activePlayback = [22]
        controller.observe(fixture.snapshot)

        #expect(controller.state.confirmed?.output.id == 22)
        #expect(controller.state.confirmed?.output.uid == "headphone")
        #expect(controller.state.phase == .confirmed)
        #expect(controller.state.error == nil)
        #expect(fixture.selections.count == writes)
    }

    @Test func aggregateMemberReconnectWithANewDeviceIDKeepsTheRoute() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.simultaneous(["speaker", "headphone"]))
        let aggregateID = fixture.selected

        fixture.outputs[1] = AudioOutput(id: 22, uid: "headphone", name: "测试耳机",
                                         transport: kAudioDeviceTransportTypeBluetooth)
        fixture.selected = aggregateID
        fixture.systemSelected = aggregateID
        fixture.activePlayback = [aggregateID]
        controller.observe(fixture.snapshot)

        #expect(controller.state.confirmed?.aggregate?.outputs.first { $0.uid == "headphone" }?.id == 22)
        #expect(controller.state.phase == .confirmed)
        #expect(controller.state.error == nil)
        #expect(fixture.destroyed.isEmpty)
    }

    @Test func oldPlaybackHandleDuringHALRenumberingDoesNotCauseFalseAdoption() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.single("speaker"), at: start)
        controller.beforeChanging = { Issue.record("HAL 换号期间不能停止会话") }

        // 默认输出变化会让整批设备换号；播放进程可能短暂仍报告旧扬声器句柄。
        fixture.outputs = [
            AudioOutput(id: 11, uid: "speaker", name: "测试扬声器", transport: kAudioDeviceTransportTypeBuiltIn),
            AudioOutput(id: 12, uid: "headphone", name: "测试耳机", transport: kAudioDeviceTransportTypeBluetooth)
        ]
        fixture.selected = 12
        fixture.systemSelected = 12
        fixture.activePlayback = [1]
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(0.2))
        #expect(controller.state.confirmed?.output.uid == "speaker")
        #expect(controller.state.error == nil)

        // 换号完成后播放进程报告新句柄，再按真实通道恢复默认输出。
        fixture.activePlayback = [11]
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(0.4))
        #expect(fixture.selected == 11 && fixture.systemSelected == 11)
        #expect(controller.state.confirmed?.output.id == 11)
        #expect(controller.state.error == nil)
    }

    @Test func initialObservationAcceptsSeparateMediaAndSoundEffectDefaults() {
        let fixture = RoutingTestHardware()
        fixture.systemSelected = 2
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.observe(fixture.snapshot)
        #expect(controller.state.confirmed?.output.uid == "speaker")
        #expect(controller.state.phase == .stable)
        #expect(controller.state.error == nil)
        #expect(controller.state.actualOutput?.uid == "speaker")
        #expect(controller.state.actualSystemOutputID == 2)
        #expect(fixture.selections.isEmpty)
    }

    @Test func snapshotFailureRetainsDiscoveredButNotOwnedCleanupRecords() throws {
        let fixture = RoutingTestHardware()
        let plan = try MultiOutputPlan(outputs: Array(fixture.outputs.prefix(2)),
                                       sampleRates: ["speaker": 48_000, "headphone": 48_000])
        fixture.compositions[88] = plan.description(uid: "local.aural.multi.previous")
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.observe(fixture.snapshot)
        #expect(controller.state.pendingCleanup.map(\.id) == [88])
        controller.observationFailed(AudioFailure("暂时无法读取快照"))
        #expect(controller.state.pendingCleanup.map(\.id) == [88])
        controller.dismissError()
        #expect(controller.state.phase == .failed)
        controller.observe(fixture.snapshot)
        controller.stop()
        #expect(controller.state.pendingCleanup.isEmpty)
        #expect(fixture.destroyed == [88])
    }

    @Test func cleanupDiscoveredInsideRequestSurvivesBothDestroyAndReadbackFailure() throws {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.observe(fixture.snapshot)
        #expect(controller.state.pendingCleanup.isEmpty)
        let plan = try MultiOutputPlan(outputs: Array(fixture.outputs.prefix(2)),
                                       sampleRates: ["speaker": 48_000, "headphone": 48_000])
        fixture.compositions[88] = plan.description(uid: "local.aural.multi.newly-discovered")
        fixture.failDestroy = true
        fixture.failSnapshotAfterDestroyError = true
        controller.request(.single("headphone"))
        #expect(controller.state.phase == .failed)
        #expect(controller.state.actualOutput == nil)
        #expect(controller.state.pendingCleanup.map(\.id) == [88])
        controller.dismissError()
        #expect(controller.state.phase == .failed)
        fixture.failSnapshot = false; fixture.failDestroy = false
        controller.request(.single("headphone"))
        #expect(controller.state.phase == .confirmed)
        #expect(controller.state.pendingCleanup.isEmpty)
    }

    @Test func postDestroySnapshotRecordsNewResidueBeforeALaterReadbackFailure() throws {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.observe(fixture.snapshot)
        let plan = try MultiOutputPlan(outputs: Array(fixture.outputs.prefix(2)),
                                       sampleRates: ["speaker": 48_000, "headphone": 48_000])
        fixture.compositions[88] = plan.description(uid: "local.aural.multi.G")
        fixture.afterDestroy = { id in
            if id == 88 {
                fixture.compositions[89] = plan.description(uid: "local.aural.multi.H")
                fixture.failSnapshotAfterNextSelection = true
            }
        }
        controller.request(.single("headphone"))
        #expect(controller.state.phase == .failed)
        #expect(controller.state.pendingCleanup.map(\.id) == [89])
        controller.dismissError()
        #expect(controller.state.phase == .failed)
        #expect(fixture.destroyed == [88])
    }

    @Test func timeoutCancelsQueuedIntentInsteadOfOverwritingAnExternalSelection() {
        let fixture = RoutingTestHardware()
        fixture.deferSelection = true
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.simultaneous(["speaker", "headphone"]), at: start)
        controller.request(.single("speaker"), at: start)
        fixture.selected = 3; fixture.systemSelected = 3
        controller.observe(fixture.snapshot, at: start.addingTimeInterval(4))
        #expect(controller.state.phase == .failed)
        #expect(controller.state.queued == nil)
        #expect(controller.state.actualOutput?.uid == "usb")
        #expect(fixture.selections.count == 1)
        #expect(fixture.selected == 3)
    }

    @Test func noEmptySelectionOrDuplicateDevicesReachHAL() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        for uids in [[], ["speaker", "speaker"], ["missing"]] {
            controller.request(.simultaneous(uids))
            #expect(controller.state.phase == .failed)
            #expect(fixture.selections.isEmpty)
            #expect(fixture.created.isEmpty)
        }
    }

    @Test func snapshotFailureDoesNotReuseStaleConfirmation() {
        let fixture = RoutingTestHardware()
        let controller = OutputRoutingController(hardware: fixture.hardware)
        controller.request(.simultaneous(["speaker", "headphone"]))
        fixture.failSnapshot = true
        controller.request(.single("headphone"))
        #expect(controller.state.phase == .failed)
        #expect(controller.state.confirmed == nil)
        #expect(controller.state.actualOutput == nil)
        #expect(controller.state.pendingCleanup.count == 1)
        #expect(controller.state.error?.contains("无法读回实际输出") == true)
    }
}
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
    var afterCreate: ((AudioDeviceID) -> Void)?
    var afterSelection: ((AudioDeviceID) -> Void)?
    var worn: [AudioDeviceID: Bool] = [:]
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
            activePlaybackDeviceIDs: { self.activePlayback }, isWorn: { self.worn[$0] }, sampleRate: { _ in 48_000 },
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
                self.afterCreate?(id)
                return id
            }, select: { id in
                self.selections.append(id)
                if self.failSnapshotAfterNextSelection { self.failSnapshot = true }
                self.pendingSelection = id
                if !self.deferSelection { self.selected = id }
                if !self.deferSelection && !self.deferSystemSelection { self.systemSelected = id }
                self.afterSelection?(id)
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
