import Testing
@testable import SPZApp

@Suite("AdaptiveConcurrencyGate")
struct AdaptiveConcurrencyGateTests {
    @Test func respectsRuntimeLimitAndRelease() {
        let gate = AdaptiveConcurrencyGate()

        #expect(gate.tryAcquire(maxConcurrent: 1))
        #expect(!gate.tryAcquire(maxConcurrent: 1))
        gate.release()
        #expect(gate.tryAcquire(maxConcurrent: 1))
    }

    @Test func canIncreaseLimitWithoutResettingInFlight() {
        let gate = AdaptiveConcurrencyGate()

        #expect(gate.tryAcquire(maxConcurrent: 1))
        #expect(gate.tryAcquire(maxConcurrent: 2))
        #expect(!gate.tryAcquire(maxConcurrent: 2))
        #expect(gate.currentInFlight == 2)
    }

    @Test func resetClearsStuckInFlightCounter() {
        let gate = AdaptiveConcurrencyGate()

        #expect(gate.tryAcquire(maxConcurrent: 1))
        gate.reset()
        #expect(gate.currentInFlight == 0)
        #expect(gate.tryAcquire(maxConcurrent: 1))
    }
}
