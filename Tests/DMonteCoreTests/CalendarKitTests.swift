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

    // MARK: - Month-grid event dots.

    /// February 2027 (28 days) as `[monthStart, monthEnd)`, the window `reloadMonthDots` queries.
    private func februaryBounds(calendar: Calendar) -> (start: Date, end: Date) {
        (date(2027, 2, 1, calendar: calendar), date(2027, 3, 1, calendar: calendar))
    }

    private func dots(start: Date, end: Date, calendar: Calendar) -> Set<Date> {
        let bounds = februaryBounds(calendar: calendar)
        return CalendarController.eventDays(
            start: start,
            end: end,
            monthStart: bounds.start,
            monthEnd: bounds.end,
            calendar: calendar
        )
    }

    func testSingleDayEventDotsOnlyItsOwnDay() {
        let calendar = makeCalendar()
        let start = date(2027, 2, 10, calendar: calendar).addingTimeInterval(9 * 3600)
        let days = dots(start: start, end: start.addingTimeInterval(3600), calendar: calendar)
        XCTAssertEqual(days, [date(2027, 2, 10, calendar: calendar)])
    }

    func testMultiDayEventDotsEveryDayItSpans() {
        let calendar = makeCalendar()
        let days = dots(
            start: date(2027, 2, 10, calendar: calendar).addingTimeInterval(9 * 3600),
            end: date(2027, 2, 12, calendar: calendar).addingTimeInterval(17 * 3600),
            calendar: calendar
        )
        XCTAssertEqual(days, Set([10, 11, 12].map { date(2027, 2, $0, calendar: calendar) }))
    }

    func testEventStartingBeforeTheMonthDotsItsInMonthDays() {
        // A conference running Jan 30 – Feb 2: February should dot the 1st and the 2nd.
        let calendar = makeCalendar()
        let days = dots(
            start: date(2027, 1, 30, calendar: calendar),
            end: date(2027, 2, 2, calendar: calendar).addingTimeInterval(17 * 3600),
            calendar: calendar
        )
        XCTAssertEqual(days, Set([1, 2].map { date(2027, 2, $0, calendar: calendar) }))
    }

    func testEventRunningPastTheMonthIsClampedToIt() {
        let calendar = makeCalendar()
        let days = dots(
            start: date(2027, 2, 27, calendar: calendar),
            end: date(2027, 3, 3, calendar: calendar),
            calendar: calendar
        )
        XCTAssertEqual(days, Set([27, 28].map { date(2027, 2, $0, calendar: calendar) }))
    }

    func testEventEndingAtMidnightDoesNotDotTheDayItEndsOn() {
        let calendar = makeCalendar()
        let days = dots(
            start: date(2027, 2, 10, calendar: calendar).addingTimeInterval(22 * 3600),
            end: date(2027, 2, 11, calendar: calendar),
            calendar: calendar
        )
        XCTAssertEqual(days, [date(2027, 2, 10, calendar: calendar)])
    }

    func testEventEntirelyBeforeTheMonthDotsNothing() {
        let calendar = makeCalendar()
        let days = dots(
            start: date(2027, 1, 5, calendar: calendar),
            end: date(2027, 1, 6, calendar: calendar),
            calendar: calendar
        )
        XCTAssertEqual(days, [], "An event that ended in January must not dot February's 1st.")
    }

    func testEventEndingExactlyAtTheMonthStartDotsNothing() {
        // New Year's Eve, viewed from the next month: Jan 31 22:00 – Feb 1 00:00 ends as February
        // begins, and the end-at-midnight rule applies across the month boundary too.
        let calendar = makeCalendar()
        let days = dots(
            start: date(2027, 1, 31, calendar: calendar).addingTimeInterval(22 * 3600),
            end: date(2027, 2, 1, calendar: calendar),
            calendar: calendar
        )
        XCTAssertEqual(days, [])
    }

    func testZeroLengthEventAtTheMonthStartDotsTheFirst() {
        let calendar = makeCalendar()
        let start = date(2027, 2, 1, calendar: calendar)
        let days = dots(start: start, end: start, calendar: calendar)
        XCTAssertEqual(days, [date(2027, 2, 1, calendar: calendar)])
    }

    // MARK: - Per-calendar filtering

    /// Stands in for an `EKEvent`: the filter only ever needs an owning-calendar identifier, so the
    /// tests never touch EventKit or the user's real calendars.
    private struct StubEvent: Equatable {
        let title: String
        let calendarID: String?
    }

    private let work = StubEvent(title: "Standup", calendarID: "work")
    private let home = StubEvent(title: "Dinner", calendarID: "home")
    private let orphan = StubEvent(title: "Unowned", calendarID: nil)

    private func visible(_ events: [StubEvent], excluding excluded: Set<String>) -> [StubEvent] {
        CalendarKit.visibleEvents(events, excludedCalendarIDs: excluded) { $0.calendarID }
    }

    func testNoExclusionsShowsEverything() {
        XCTAssertEqual(visible([work, home, orphan], excluding: []), [work, home, orphan])
    }

    func testExcludedCalendarsEventsAreHidden() {
        XCTAssertEqual(visible([work, home], excluding: ["work"]), [home])
    }

    func testFilteringPreservesOrder() {
        let events = [home, work, home, work]
        XCTAssertEqual(visible(events, excluding: ["work"]), [home, home])
    }

    func testExcludingEveryCalendarLeavesNothing() {
        XCTAssertEqual(visible([work, home], excluding: ["work", "home"]), [])
    }

    func testUnknownCalendarStaysVisible() {
        // The whole point of storing exclusions: a calendar nobody has hidden — including one added
        // after the filter was last edited — must still show up.
        XCTAssertEqual(visible([work, home], excluding: ["archive"]), [work, home])
    }

    func testEventWithNoOwningCalendarStaysVisible() {
        XCTAssertEqual(visible([orphan], excluding: ["work", "home"]), [orphan])
    }

    func testIsCalendarVisibleMatchesTheExclusionSet() {
        XCTAssertFalse(CalendarKit.isCalendarVisible("work", excludedCalendarIDs: ["work"]))
        XCTAssertTrue(CalendarKit.isCalendarVisible("home", excludedCalendarIDs: ["work"]))
        XCTAssertTrue(CalendarKit.isCalendarVisible(nil, excludedCalendarIDs: ["work"]))
    }

    // MARK: - Toggling the filter

    func testHidingACalendarAddsItToTheExclusions() {
        let updated = CalendarKit.excludedCalendarIDs([], setting: "work", visible: false)
        XCTAssertEqual(updated, ["work"])
    }

    func testShowingACalendarRemovesItFromTheExclusions() {
        let updated = CalendarKit.excludedCalendarIDs(["work", "home"], setting: "work", visible: true)
        XCTAssertEqual(updated, ["home"])
    }

    func testTogglingIsIdempotent() {
        XCTAssertEqual(CalendarKit.excludedCalendarIDs(["work"], setting: "work", visible: false), ["work"])
        XCTAssertEqual(CalendarKit.excludedCalendarIDs([], setting: "work", visible: true), [])
    }

    func testHideThenShowRoundTripsToTheOriginalSet() {
        let hidden = CalendarKit.excludedCalendarIDs(["home"], setting: "work", visible: false)
        XCTAssertEqual(CalendarKit.excludedCalendarIDs(hidden, setting: "work", visible: true), ["home"])
    }

    // MARK: - Filter persistence

    func testExclusionsRoundTripThroughDefaults() {
        let suiteName = "CalendarKitTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(CalendarKit.persistedExcludedCalendarIDs(defaults: defaults), [])

        CalendarKit.persistExcludedCalendarIDs(["work", "home"], defaults: defaults)
        XCTAssertEqual(CalendarKit.persistedExcludedCalendarIDs(defaults: defaults), ["work", "home"])

        CalendarKit.persistExcludedCalendarIDs([], defaults: defaults)
        XCTAssertEqual(
            CalendarKit.persistedExcludedCalendarIDs(defaults: defaults),
            [],
            "Clearing the filter must leave nothing behind to hide calendars later."
        )
    }

    func testPersistedExclusionsAreStoredSorted() {
        let suiteName = "CalendarKitTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        CalendarKit.persistExcludedCalendarIDs(["work", "archive", "home"], defaults: defaults)
        XCTAssertEqual(
            defaults.stringArray(forKey: DefaultsKey.calendarExcludedCalendarIDs),
            ["archive", "home", "work"]
        )
    }

    func testPersistenceKeepsIdentifiersThatNoLongerResolve() {
        // The load-bearing persistence decision: an offline or deleted calendar's identifier must
        // survive a save/load cycle, otherwise a deliberately hidden calendar un-hides itself the
        // next time its account comes back.
        let suiteName = "CalendarKitTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        CalendarKit.persistExcludedCalendarIDs(["work", "gone-offline"], defaults: defaults)
        let loaded = CalendarKit.persistedExcludedCalendarIDs(defaults: defaults)
        XCTAssertEqual(loaded, ["work", "gone-offline"])

        // Toggling an unrelated calendar must not quietly drop the unresolvable one.
        let updated = CalendarKit.excludedCalendarIDs(loaded, setting: "home", visible: false)
        CalendarKit.persistExcludedCalendarIDs(updated, defaults: defaults)
        XCTAssertEqual(
            CalendarKit.persistedExcludedCalendarIDs(defaults: defaults),
            ["work", "gone-offline", "home"]
        )
    }

    func testPersistenceSurvivesUnicodeAndEmptyIdentifiers() {
        let suiteName = "CalendarKitTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let awkward: Set<String> = ["", "日本のカレンダー", "a b/c", "🎉"]
        CalendarKit.persistExcludedCalendarIDs(awkward, defaults: defaults)
        XCTAssertEqual(CalendarKit.persistedExcludedCalendarIDs(defaults: defaults), awkward)
    }

    // MARK: - "Is anything actually hidden?"

    func testNothingIsHiddenWithAnEmptyExclusionSet() {
        XCTAssertFalse(CalendarKit.hasHiddenCalendars(among: ["work", "home"], excludedCalendarIDs: []))
    }

    func testHidingALiveCalendarCountsAsFiltering() {
        XCTAssertTrue(CalendarKit.hasHiddenCalendars(among: ["work", "home"], excludedCalendarIDs: ["work"]))
    }

    func testAStaleExclusionDoesNotCountAsFiltering() {
        // A calendar deleted (or an account removed) while hidden leaves its identifier behind on
        // purpose. Nothing is being filtered any more, so the UI must not claim otherwise.
        XCTAssertFalse(
            CalendarKit.hasHiddenCalendars(among: ["work", "home"], excludedCalendarIDs: ["deleted"]),
            "A leftover identifier for a calendar that no longer exists must not light the filter indicator."
        )
    }

    func testNoCalendarsMeansNothingIsHidden() {
        XCTAssertFalse(CalendarKit.hasHiddenCalendars(among: [], excludedCalendarIDs: ["work"]))
    }

    // MARK: - Calendar.app deep links

    func testEventShowURLPutsTheIdentifierInTheOnlyPathComponent() {
        let calendar = makeCalendar()
        let occurrence = date(2027, 2, 10, calendar: calendar).addingTimeInterval(9 * 3600 + 30 * 60)
        let url = CalendarKit.eventShowURL(eventIdentifier: "ABC-123", occurrenceDate: occurrence)
        XCTAssertEqual(url?.absoluteString, "ical://ekevent/ABC-123?method=show&options=more")
    }

    func testEventShowURLIsTheSameWithOrWithoutAnOccurrenceDate() {
        let calendar = makeCalendar()
        let withDate = CalendarKit.eventShowURL(
            eventIdentifier: "ABC-123",
            occurrenceDate: date(2027, 2, 10, calendar: calendar)
        )
        let withoutDate = CalendarKit.eventShowURL(eventIdentifier: "ABC-123", occurrenceDate: nil)
        XCTAssertEqual(withDate, withoutDate)
    }

    /// KNOWN LIMITATION, asserted so it is visible rather than forgotten.
    ///
    /// Every occurrence of a recurring event shares one `eventIdentifier`, so this URL cannot
    /// distinguish them — all occurrences open the same event. An earlier version prefixed the
    /// occurrence date to disambiguate, which produced distinct URLs that Calendar.app did not
    /// accept at all: it opened on today's date instead of the event. A URL that works and is
    /// imprecise beats one that is precise and does nothing.
    ///
    /// Whatever replaces this has to be confirmed against a live Calendar.app; no unit test can
    /// tell us which shape that app actually resolves.
    func testOccurrencesOfOneSeriesCurrentlyShareAURL() {
        let calendar = makeCalendar()
        let first = CalendarKit.eventShowURL(
            eventIdentifier: "SERIES",
            occurrenceDate: date(2027, 2, 10, calendar: calendar)
        )
        let second = CalendarKit.eventShowURL(
            eventIdentifier: "SERIES",
            occurrenceDate: date(2027, 2, 17, calendar: calendar)
        )
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
    }

    func testEventShowURLIsNilWithoutAnIdentifier() {
        let calendar = makeCalendar()
        let occurrence = date(2027, 2, 10, calendar: calendar)
        XCTAssertNil(CalendarKit.eventShowURL(eventIdentifier: nil, occurrenceDate: occurrence))
        XCTAssertNil(CalendarKit.eventShowURL(eventIdentifier: "", occurrenceDate: occurrence))
    }

    func testEventShowURLEscapesAwkwardIdentifiers() {
        // EventKit identifiers are opaque; a space or a hash must not truncate or break the URL.
        let url = CalendarKit.eventShowURL(eventIdentifier: "id with space#1", occurrenceDate: nil)
        XCTAssertEqual(url?.absoluteString, "ical://ekevent/id%20with%20space%231?method=show&options=more")
    }

    func testEventShowURLKeepsTheIdentifierInOnePathComponent() {
        // A slash is legal in a URL path, so an unescaped one would silently address a different
        // event rather than fail: the identifier must stay a single component.
        let calendar = makeCalendar()
        let url = CalendarKit.eventShowURL(
            eventIdentifier: "acct/one:evt",
            occurrenceDate: date(2027, 2, 10, calendar: calendar)
        )
        XCTAssertEqual(
            url?.absoluteString,
            "ical://ekevent/acct%2Fone:evt?method=show&options=more"
        )
        XCTAssertEqual(url?.pathComponents.count, 2, "Expected / and the identifier — a slash inside the identifier must not split it.")
        XCTAssertEqual(url?.pathComponents.last, "acct/one:evt")
    }

    func testEventShowURLEscapesAPercentInTheIdentifier() {
        // `%` is the escape marker itself, so an identifier that already looks escaped — `%2F` reading
        // as a slash — must survive as literal text rather than decoding into a different address.
        let url = CalendarKit.eventShowURL(eventIdentifier: "id%2Fother", occurrenceDate: nil)
        XCTAssertEqual(url?.absoluteString, "ical://ekevent/id%252Fother?method=show&options=more")
        XCTAssertEqual(url?.pathComponents.count, 2, "Expected / and the identifier.")
        XCTAssertEqual(url?.pathComponents.last, "id%2Fother")
    }

    func testEventShowURLRoundTripsAUnicodeIdentifier() {
        let identifier = "café-日程-🎉"
        let url = CalendarKit.eventShowURL(eventIdentifier: identifier, occurrenceDate: nil)
        XCTAssertEqual(url?.pathComponents.last, identifier)
    }

    func testUTCStampIsIndependentOfTheHostTimezone() {
        // The stamp is always UTC: the same instant must serialise identically wherever the test runs.
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(CalendarKit.utcStamp(for: instant), "20270115T080000Z")
    }
}
