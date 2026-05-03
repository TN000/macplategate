import Testing
import Foundation
@testable import SPZApp

@Suite("NightPause")
@MainActor
struct NightPauseTests {

    private func makeState(enabled: Bool, start: Int, end: Int) -> AppState {
        let s = AppState()
        s.nightPauseEnabled = enabled
        s.nightPauseStartHour = start
        s.nightPauseEndHour = end
        return s
    }

    private func date(hour: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 4; c.day = 27
        c.hour = hour; c.minute = 30
        return Calendar.current.date(from: c)!
    }

    @Test func disabledAlwaysFalse() {
        let s = makeState(enabled: false, start: 23, end: 5)
        #expect(s.isInNightPause(at: date(hour: 0)) == false)
        #expect(s.isInNightPause(at: date(hour: 12)) == false)
        #expect(s.isInNightPause(at: date(hour: 23)) == false)
    }

    @Test func wraparoundWindow() {
        // 23 → 5 = pause 23:00, 00:00, 01:00, 02:00, 03:00, 04:00; ne 05:00 dál.
        let s = makeState(enabled: true, start: 23, end: 5)
        #expect(s.isInNightPause(at: date(hour: 22)) == false)
        #expect(s.isInNightPause(at: date(hour: 23)) == true)
        #expect(s.isInNightPause(at: date(hour: 0)) == true)
        #expect(s.isInNightPause(at: date(hour: 4)) == true)
        #expect(s.isInNightPause(at: date(hour: 5)) == false)
        #expect(s.isInNightPause(at: date(hour: 12)) == false)
    }

    @Test func sameDayWindow() {
        // 9 → 17 = pause 9:00 – 16:59.
        let s = makeState(enabled: true, start: 9, end: 17)
        #expect(s.isInNightPause(at: date(hour: 8)) == false)
        #expect(s.isInNightPause(at: date(hour: 9)) == true)
        #expect(s.isInNightPause(at: date(hour: 16)) == true)
        #expect(s.isInNightPause(at: date(hour: 17)) == false)
    }

    @Test func zeroLengthWindow() {
        // start == end → vypnuto (žádné hodiny v okně).
        let s = makeState(enabled: true, start: 5, end: 5)
        for h in 0..<24 {
            #expect(s.isInNightPause(at: date(hour: h)) == false)
        }
    }
}
