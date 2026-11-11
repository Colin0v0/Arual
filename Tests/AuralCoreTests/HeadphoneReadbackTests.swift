import Foundation
import Testing
@testable import AuralCore

struct HeadphoneReadbackTests {
    @Test func oldRefreshCannotFinishAnUnsentOrUnverifiedSet() {
        var gate = NoiseReadbackGate()
        gate.begin(.cancellation)
        #expect(!gate.confirms(.off))
        #expect(!gate.confirms(.cancellation))
        gate.didSendWrite()
        #expect(!gate.confirms(.cancellation))
        gate.didSendVerification()
        #expect(!gate.confirms(.off))
        #expect(gate.confirms(.cancellation))
        gate.clear()
        #expect(!gate.confirms(.cancellation))
    }

    @Test func aNewRequestResetsThePreviousVerification() {
        var gate = NoiseReadbackGate()
        gate.begin(.off); gate.didSendWrite(); gate.didSendVerification()
        gate.begin(.transparency)
        #expect(!gate.confirms(.off))
        #expect(!gate.confirms(.transparency))
        gate.didSendVerification()
        #expect(!gate.confirms(.transparency))
    }

    @Test func chargingStatusRequiresAValidConfirmedResponse() throws {
        var state = BowersWilkinsState()
        let refusal = BWRPCMessage(kind: .response, command: BWRPCatalog.chargingGet, errorCode: 1, payload: nil)
        #expect(try !state.applyRefresh(refusal, profile: .standard))
        #expect(state.isCharging == nil)
        let charging = BWRPCMessage(kind: .response, command: BWRPCatalog.chargingGet, errorCode: 0, payload: .bool(true))
        #expect(try state.applyRefresh(charging, profile: .standard))
        #expect(state.isCharging == true)
        let unplugged = BWRPCMessage(kind: .response, command: BWRPCatalog.chargingGet, errorCode: 0, payload: .bool(false))
        try state.apply(unplugged)
        #expect(state.isCharging == false)
        let malformed = BWRPCMessage(kind: .response, command: BWRPCatalog.chargingGet, errorCode: 0, payload: .int(1))
        #expect(throws: (any Error).self) { try state.apply(malformed) }
        #expect(throws: (any Error).self) { _ = try state.applyRefresh(refusal, profile: .standard) }
    }

    @Test func onlyInitialAncCapabilityRefusalCanKeepBattery() throws {
        let refusal = BWRPCMessage(kind: .response, command: BWRPCatalog.ancGet, errorCode: 1, payload: nil)
        var unknown = BowersWilkinsState()
        let supported = try unknown.applyRefresh(refusal, profile: .standard)
        #expect(!supported && unknown.noiseMode == nil)
        var known = BowersWilkinsState()
        let read = BWRPCMessage(kind: .response, command: BWRPCatalog.ancGet, errorCode: 0, payload: .int(1))
        let confirmed = try known.applyRefresh(read, profile: .standard)
        #expect(confirmed && known.noiseMode == .cancellation)
        #expect(throws: (any Error).self) { _ = try known.applyRefresh(refusal, profile: .standard) }
    }
}
