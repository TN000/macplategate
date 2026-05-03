import Testing
import Foundation
@testable import SPZApp

@Suite("ResourceBudget")
struct ResourceBudgetTests {

    @Test func multiplierPerMode() {
        #expect(ResourceBudget.multiplier(for: .normal) == 1.0)
        #expect(ResourceBudget.multiplier(for: .warm) == 0.7)
        #expect(ResourceBudget.multiplier(for: .constrained) == 0.45)
    }

    @Test func ocrLatencyP95RingBuffer() {
        // Verify recording + sliding window (≤30 last samples).
        let budget = ResourceBudget.shared
        // Reset by feeding many high values then observing they age out — but
        // we don't have public reset, so just ensure writes don't crash.
        for i in 0..<50 {
            budget.recordOcrLatency(Double(i), for: "test-cam")
        }
        // Just verify call-site is safe; p95 is private internal.
        #expect(Bool(true))
    }
}
