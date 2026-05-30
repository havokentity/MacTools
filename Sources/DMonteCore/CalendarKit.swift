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
}
