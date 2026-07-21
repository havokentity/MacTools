import CoreGraphics
import Foundation

/// Pure, UI-free month-grid math used by the menu-bar Calendar tool. Everything here is Foundation
/// only and fully deterministic: callers pass in `today` and a `Calendar`, so the output never
/// depends on the wall clock or the system locale. This makes the grid trivially unit-testable and
/// keeps EventKit (which needs permission and a real event store) out of the testable core.
public enum CalendarKit {
    /// A single cell in the month grid. Leading/trailing days that fall outside the displayed month
    /// are represented as `nil` in `MonthGrid.weeks`, so a populated `CalendarDay` is always a real,
    /// in-month day.
    public struct CalendarDay: Sendable, Identifiable {
        /// Stable identity for SwiftUI: the day-of-month number, which is unique within a month grid.
        public let id: Int
        /// Midnight (in the supplied calendar's timezone) of this day.
        public let date: Date
        /// Day-of-month number, 1...31.
        public let day: Int
        /// `true` when this day is the supplied `today`.
        public let isToday: Bool
        /// Always `true` for a populated cell; kept for clarity at call sites and future-proofing.
        public let inMonth: Bool

        public init(id: Int, date: Date, day: Int, isToday: Bool, inMonth: Bool) {
            self.id = id
            self.date = date
            self.day = day
            self.isToday = isToday
            self.inMonth = inMonth
        }
    }

    /// A full month laid out as 6 rows of 7 columns. `nil` entries are the leading blanks before the
    /// 1st and the trailing blanks after the last day, so the grid is always rectangular.
    public struct MonthGrid: Sendable {
        public let year: Int
        public let month: Int
        public let weeks: [[CalendarDay?]]

        public init(year: Int, month: Int, weeks: [[CalendarDay?]]) {
            self.year = year
            self.month = month
            self.weeks = weeks
        }

        /// All populated (in-month) days in calendar order. Handy for tests and event-dot lookups.
        public var days: [CalendarDay] {
            weeks.flatMap { $0 }.compactMap { $0 }
        }
    }

    /// Builds a 6×7 month grid for `month`/`year`.
    ///
    /// - Parameters:
    ///   - year: Gregorian (or supplied-calendar) year, e.g. `2027`.
    ///   - month: Month number `1...12`.
    ///   - firstWeekday: The weekday that starts each row, `1 == Sunday ... 7 == Saturday`
    ///     (matching `Calendar.firstWeekday`). Leading blanks are computed so day 1 lands in the
    ///     correct column for this start-of-week.
    ///   - today: The date considered "today"; the matching cell gets `isToday == true`. Passed in
    ///     so tests are deterministic.
    ///   - calendar: The calendar used for all date math. Pass a fixed `Calendar(identifier:
    ///     .gregorian)` with an explicit timezone in tests for determinism.
    /// - Returns: A `MonthGrid` with exactly 6 rows × 7 columns; leading/trailing cells are `nil`.
    public static func monthGrid(
        year: Int,
        month: Int,
        firstWeekday: Int,
        today: Date,
        calendar: Calendar
    ) -> MonthGrid {
        var cal = calendar
        cal.firstWeekday = firstWeekday

        // First day of the month at midnight in the calendar's timezone.
        var startComponents = DateComponents()
        startComponents.year = year
        startComponents.month = month
        startComponents.day = 1
        startComponents.hour = 0
        startComponents.minute = 0
        startComponents.second = 0

        guard let firstOfMonth = cal.date(from: startComponents),
              let dayRange = cal.range(of: .day, in: .month, for: firstOfMonth) else {
            // Degrade to an all-blank grid rather than crashing on a nonsensical month/year.
            let blankWeeks = Array(repeating: Array(repeating: CalendarDay?.none, count: 7), count: 6)
            return MonthGrid(year: year, month: month, weeks: blankWeeks)
        }

        let numberOfDays = dayRange.count

        // The weekday of the 1st (1 == Sunday ... 7 == Saturday). The number of leading blanks is
        // how far that weekday is past `firstWeekday`, wrapped into 0...6.
        let weekdayOfFirst = cal.component(.weekday, from: firstOfMonth)
        let leadingBlanks = ((weekdayOfFirst - firstWeekday) + 7) % 7

        // Normalise `today` to its midnight so equality is a pure same-day comparison.
        let todayStart = cal.startOfDay(for: today)

        // Flatten into 42 cells, then chunk into 6 rows of 7.
        var cells: [CalendarDay?] = Array(repeating: nil, count: leadingBlanks)

        for day in 1...numberOfDays {
            guard let date = cal.date(byAdding: .day, value: day - 1, to: firstOfMonth) else {
                cells.append(nil)
                continue
            }
            let isToday = cal.isDate(date, inSameDayAs: todayStart)
            cells.append(
                CalendarDay(id: day, date: date, day: day, isToday: isToday, inMonth: true)
            )
        }

        // Pad to a full 6×7 = 42 cells so every grid is the same rectangular shape.
        let totalCells = 42
        if cells.count < totalCells {
            cells.append(contentsOf: Array(repeating: nil, count: totalCells - cells.count))
        } else if cells.count > totalCells {
            cells = Array(cells.prefix(totalCells))
        }

        var weeks: [[CalendarDay?]] = []
        weeks.reserveCapacity(6)
        for week in 0..<6 {
            let start = week * 7
            weeks.append(Array(cells[start..<(start + 7)]))
        }

        return MonthGrid(year: year, month: month, weeks: weeks)
    }

    /// Weekday header symbols (e.g. "S", "M", ...) ordered to start at `firstWeekday`. Uses the
    /// supplied calendar's locale via `DateFormatter` so headers respect the user's locale; pass a
    /// fixed calendar/locale in tests for determinism.
    public static func weekdaySymbols(firstWeekday: Int, calendar: Calendar) -> [String] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? Locale.current
        // `veryShortStandaloneWeekdaySymbols` is Sunday-first (index 0 == Sunday).
        let base = formatter.veryShortStandaloneWeekdaySymbols
            ?? ["S", "M", "T", "W", "T", "F", "S"]
        guard base.count == 7 else { return base }
        let offset = (firstWeekday - 1 + 7) % 7
        return (0..<7).map { base[($0 + offset) % 7] }
    }

    /// Month + year title, e.g. "February 2027", localized via the supplied calendar.
    public static func monthTitle(year: Int, month: Int, calendar: Calendar) -> String {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        guard let date = calendar.date(from: components) else { return "" }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? Locale.current
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: date)
    }

    // MARK: - Per-calendar filtering

    /// Whether events owned by `calendarID` should be shown.
    ///
    /// The filter is stored as the set of *excluded* calendars, so anything unknown — a calendar the
    /// user has never touched, one added after the last time the filter was edited, or an event whose
    /// owning calendar EventKit could not resolve — is visible. Storing the inclusions instead would
    /// make a newly-added calendar silently invisible.
    public static func isCalendarVisible(_ calendarID: String?, excludedCalendarIDs: Set<String>) -> Bool {
        guard let calendarID else { return true }
        return !excludedCalendarIDs.contains(calendarID)
    }

    /// Filters `events` down to those whose owning calendar is not excluded, preserving order.
    ///
    /// Generic over the element and its calendar lookup so the rule lives here — free of EventKit —
    /// and can be applied identically to `EKEvent`s (for the month-grid dots) and to the view's own
    /// row model (for the day/upcoming lists).
    public static func visibleEvents<Event>(
        _ events: [Event],
        excludedCalendarIDs: Set<String>,
        calendarID: (Event) -> String?
    ) -> [Event] {
        guard !excludedCalendarIDs.isEmpty else { return events }
        return events.filter { isCalendarVisible(calendarID($0), excludedCalendarIDs: excludedCalendarIDs) }
    }

    /// The exclusion set that results from showing (`visible == true`) or hiding a single calendar.
    /// Pure so the toggle can be asserted without touching user defaults.
    public static func excludedCalendarIDs(
        _ excluded: Set<String>,
        setting calendarID: String,
        visible: Bool
    ) -> Set<String> {
        var result = excluded
        if visible {
            result.remove(calendarID)
        } else {
            result.insert(calendarID)
        }
        return result
    }

    /// Whether any calendar that currently exists is hidden — i.e. whether the lists are actually
    /// showing less than everything.
    ///
    /// Deliberately not `!excludedCalendarIDs.isEmpty`: the stored set is never pruned (see
    /// `persistedExcludedCalendarIDs`), so an identifier left behind by a deleted calendar or a
    /// removed account would otherwise keep the "filtering" indicator lit forever while nothing is
    /// being filtered. This answers the question the UI actually asks without dropping the
    /// identifiers that let a returning calendar stay hidden.
    public static func hasHiddenCalendars(
        among calendarIDs: some Sequence<String>,
        excludedCalendarIDs: Set<String>
    ) -> Bool {
        guard !excludedCalendarIDs.isEmpty else { return false }
        return calendarIDs.contains { excludedCalendarIDs.contains($0) }
    }

    // MARK: - Filter persistence

    /// The persisted set of hidden calendar identifiers. Never migrates or prunes identifiers that no
    /// longer resolve: an account can be temporarily offline, and dropping its identifier would make a
    /// deliberately hidden calendar reappear the next time it comes back.
    public static func persistedExcludedCalendarIDs(defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: DefaultsKey.calendarExcludedCalendarIDs) ?? [])
    }

    /// Persists the hidden-calendar set. Sorted on the way out so the stored plist is stable and
    /// diffable rather than reordering on every write.
    public static func persistExcludedCalendarIDs(_ identifiers: Set<String>, defaults: UserDefaults) {
        defaults.set(identifiers.sorted(), forKey: DefaultsKey.calendarExcludedCalendarIDs)
    }

    // MARK: - Click-through to Calendar.app

    /// The `ical://` URL that reveals an event in Calendar.app, or `nil` when the event has no
    /// identifier to address.
    ///
    /// - Parameters:
    ///   - eventIdentifier: `EKEvent.eventIdentifier` — the *series* identifier, which every
    ///     occurrence of a recurring event shares.
    ///   - occurrenceDate: `EKEvent.occurrenceDate`, the occurrence's originally scheduled start.
    ///     Because the identifier alone cannot distinguish two occurrences, it is prefixed as a UTC
    ///     timestamp path component; without it Calendar.app opens the series' first occurrence.
    ///     A detached (moved) occurrence keeps its original date, which is exactly what this URL
    ///     needs, so the stamp must not be taken from `startDate`.
    /// Whether two calendar colours are the same to the eye.
    ///
    /// Compared componentwise in a shared colour space rather than with `==`: `CGColor` equality
    /// also considers the colour space object, so the same visual red arriving from two calendars
    /// can compare unequal and produce two identical-looking dots on one day.
    public static func colorsMatch(_ lhs: CGColor, _ rhs: CGColor, tolerance: CGFloat = 0.01) -> Bool {
        guard let a = lhs.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
              let b = rhs.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
              let ca = a.components, let cb = b.components,
              ca.count == cb.count else {
            return lhs == rhs
        }
        return zip(ca, cb).allSatisfy { abs($0 - $1) <= tolerance }
    }

    public static func eventShowURL(eventIdentifier: String?, occurrenceDate: Date?) -> URL? {
        guard let eventIdentifier, !eventIdentifier.isEmpty,
              let escaped = eventIdentifier.addingPercentEncoding(withAllowedCharacters: pathComponentAllowed) else {
            return nil
        }
        // `options=more` opens the full inspector rather than the compact popover.
        //
        // The identifier is the only path component. An earlier version prefixed the occurrence
        // date — `ical://ekevent/<stamp>/<id>` — reasoning that recurring occurrences share one
        // identifier and the date would disambiguate them. Calendar.app does not accept that
        // shape: reported from a real install, it launched and then sat on today's date instead
        // of the event, which is what an unresolvable URL looks like from the outside.
        //
        // `occurrenceDate` is kept in the signature because callers pass it and because pinning
        // the right occurrence is still the open question — see the tests, which lock in the
        // shape rather than the behaviour, since only a live Calendar.app can confirm the latter.
        _ = occurrenceDate
        return URL(string: "ical://ekevent/\(escaped)?method=show&options=more")
    }

    /// `.urlPathAllowed` minus `/`. The identifier is one path component, but EventKit identifiers are
    /// opaque, so a slash inside one would otherwise pass through unescaped and split the URL into
    /// extra components — addressing something else entirely instead of failing loudly.
    private static let pathComponentAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))

    /// `yyyyMMddTHHmmssZ` in UTC, the shape Calendar.app's URL scheme expects for the occurrence path
    /// component. Built from `DateComponents` rather than a `DateFormatter` so it needs no shared
    /// mutable formatter state and no locale.
    static func utcStamp(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }
}
