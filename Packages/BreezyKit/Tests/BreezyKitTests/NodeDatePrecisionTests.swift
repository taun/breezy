import Testing
@testable import BreezyKit

@Suite struct NodeDatePrecisionTests {
    @Test func yearToDayInThisYearStartsAtToday() {
        let d = NodeDate(iso: "2026-01-01", precision: .year).changingPrecision(to: .day, todayISO: "2026-10-25")
        #expect(d == NodeDate(iso: "2026-10-25", precision: .day))
    }

    @Test func yearToDayInOtherYearKeepsYear() {
        let d = NodeDate(iso: "2018-01-01", precision: .year).changingPrecision(to: .day, todayISO: "2026-10-25")
        #expect(d == NodeDate(iso: "2018-01-01", precision: .day))
    }

    @Test func dayToYearKeepsIso() {
        let d = NodeDate(iso: "2026-03-04", precision: .day).changingPrecision(to: .year, todayISO: "2026-10-25")
        #expect(d == NodeDate(iso: "2026-03-04", precision: .year))
    }
}
