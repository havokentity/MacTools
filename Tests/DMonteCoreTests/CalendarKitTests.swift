import XCTest
import Foundation
@testable import DMonteCore

final class CalendarKitTests: XCTestCase {

    /// A fixed Gregorian calendar in UTC so all month math is deterministic regardless of the host
    /// timezone/locale.
    private func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// Builds a UTC midnight `Date` for the given components, for use as a deterministic `today`.
    private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        components.minute = 0
        components.second = 0
        return calendar.date(from: components)!
    }

    private func inMonthDays(_ grid: CalendarKit.MonthGrid) -> [CalendarKit.CalendarDay] {
        grid.weeks.flatMap { $0 }.compactMap { $0 }
    }

    // MARK: - February 2027: 28 days, the 1st is a Monday.

    func testFebruary2027Structure() {
        let calendar = makeCalendar()
        let today = date(2027, 2, 15, calendar: calendar)

        // firstWeekday = 1 (Sunday).
        let grid = CalendarKit.monthGrid(
            year: 2027,
            month: 2,
            firstWeekday: 1,
            today: today,
            calendar: calendar
        )

        // Always 6 rows of 7 columns.
        XCTAssertEqual(grid.weeks.count, 6, "Grid should always have 6 weeks.")
        for week in grid.weeks {
            XCTAssertEqual(week.count, 7, "Each week should have 7 columns.")
        }

        // February 2027 has 28 in-month days.
        let days = inMonthDays(grid)
        XCTAssertEqual(days.count, 28, "February 2027 should have 28 in-month days.")

        // Day numbers run 1...28 in order.
        XCTAssertEqual(days.map { $0.day }, Array(1...28))

        // The 1st of Feb 2027 is a Monday. With Sunday-first weeks, Monday is column index 1, so the
        // first row should be [nil, day1, day2, ..., day6].
        let firstRow = grid.weeks[0]
        XCTAssertNil(firstRow[0], "Sunday cell before a Monday-start month must be blank.")
        XCTAssertEqual(firstRow[1]?.day, 1, "Day 1 should land in the Monday column (index 1).")
        XCTAssertEqual(firstRow[2]?.day, 2)
        XCTAssertEqual(firstRow[6]?.day, 6)
    }

    func testFebruary2027LeadingBlanksAreNil() {
        let calendar = makeCalendar()
        let today = date(2027, 2, 15, calendar: calendar)
        let grid = CalendarKit.monthGrid(
            year: 2027,
            month: 2,
            firstWeekday: 1,
            today: today,
            calendar: calendar
        )

        // Exactly one leading blank (the Sunday before Monday the 1st).
        XCTAssertNil(grid.weeks[0][0])
        XCTAssertNotNil(grid.weeks[0][1])
    }

    func testTodayHighlightOnlyOnMatchingDate() {
        let calendar = makeCalendar()
        let today = date(2027, 2, 15, calendar: calendar)
        let grid = CalendarKit.monthGrid(
            year: 2027,
            month: 2,
            firstWeekday: 1,
            today: today,
            calendar: calendar
        )

        let todayCells = inMonthDays(grid).filter { $0.isToday }
        XCTAssertEqual(todayCells.count, 1, "Exactly one cell should be marked as today.")
        XCTAssertEqual(todayCells.first?.day, 15, "The 15th should be the today cell.")
    }

    func testTodayOutsideDisplayedMonthHasNoHighlight() {
        let calendar = makeCalendar()
        // today is in March, but we render February: no cell should be `isToday`.
        let today = date(2027, 3, 10, calendar: calendar)
        let grid = CalendarKit.monthGrid(
            year: 2027,
            month: 2,
            firstWeekday: 1,
            today: today,
            calendar: calendar
        )

        XCTAssertTrue(inMonthDays(grid).allSatisfy { !$0.isToday })
    }

    // MARK: - A 31-day month: January 2027 (the 1st is a Friday).

    func test31DayMonth() {
        let calendar = makeCalendar()
        let today = date(2027, 1, 1, calendar: calendar)
        let grid = CalendarKit.monthGrid(
            year: 2027,
            month: 1,
            firstWeekday: 1,
            today: today,
            calendar: calendar
        )

        let days = inMonthDays(grid)
        XCTAssertEqual(days.count, 31, "January should have 31 in-month days.")
        XCTAssertEqual(days.map { $0.day }, Array(1...31))

        // Jan 1 2027 is a Friday → Sunday-first column index 5. First 5 cells are blank.
        let firstRow = grid.weeks[0]
        for column in 0..<5 {
            XCTAssertNil(firstRow[column], "Leading cell \(column) should be blank.")
        }
        XCTAssertEqual(firstRow[5]?.day, 1, "Day 1 should land in the Friday column (index 5).")
    }

    // MARK: - Leap February: February 2028 (29 days, the 1st is a Tuesday).

    func testLeapFebruary2028() {
        let calendar = makeCalendar()
        let today = date(2028, 2, 29, calendar: calendar)
        let grid = CalendarKit.monthGrid(
            year: 2028,
            month: 2,
            firstWeekday: 1,
            today: today,
            calendar: calendar
        )

        let days = inMonthDays(grid)
        XCTAssertEqual(days.count, 29, "Leap February 2028 should have 29 in-month days.")
        XCTAssertEqual(days.last?.day, 29)

        // The 29th exists and is correctly flagged as today.
        let todayCells = days.filter { $0.isToday }
        XCTAssertEqual(todayCells.count, 1)
        XCTAssertEqual(todayCells.first?.day, 29)

        // Feb 1 2028 is a Tuesday → Sunday-first column index 2.
        let firstRow = grid.weeks[0]
        XCTAssertNil(firstRow[0])
        XCTAssertNil(firstRow[1])
        XCTAssertEqual(firstRow[2]?.day, 1, "Day 1 should land in the Tuesday column (index 2).")
    }

    // MARK: - firstWeekday is respected.

    func testMondayFirstWeekdayShiftsColumns() {
        let calendar = makeCalendar()
        let today = date(2027, 2, 15, calendar: calendar)

        // Feb 1 2027 is a Monday. With firstWeekday = 2 (Monday), day 1 should be in column 0.
        let grid = CalendarKit.monthGrid(
            year: 2027,
            month: 2,
            firstWeekday: 2,
            today: today,
            calendar: calendar
        )

        let firstRow = grid.weeks[0]
        XCTAssertEqual(firstRow[0]?.day, 1, "With Monday-first weeks, a Monday 1st has no leading blanks.")
        XCTAssertEqual(inMonthDays(grid).count, 28)
    }

    // MARK: - Trailing cells beyond the last day are nil.

    func testTrailingCellsAreNil() {
        let calendar = makeCalendar()
        let today = date(2027, 2, 15, calendar: calendar)
        let grid = CalendarKit.monthGrid(
            year: 2027,
            month: 2,
            firstWeekday: 1,
            today: today,
            calendar: calendar
        )

        // 1 leading blank + 28 days = 29 populated cells; the remaining 13 of 42 are nil.
        let flattened = grid.weeks.flatMap { $0 }
        XCTAssertEqual(flattened.count, 42)
        let trailing = flattened.suffix(13)
        XCTAssertTrue(trailing.allSatisfy { $0 == nil }, "All trailing cells should be blank.")
    }
}
