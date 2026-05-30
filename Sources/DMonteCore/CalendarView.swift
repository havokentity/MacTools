import AppKit
import EventKit
import SwiftUI

/// Authorization state for the calendar store, mapped onto a small UI-friendly enum so the view can
/// branch without importing EventKit's raw status values.
public enum CalendarAccessState: Sendable, Equatable {
    /// We haven't asked yet (or the system hasn't decided).
    case notDetermined
    /// Full access granted — events can be read.
    case authorized
    /// The user denied or restricted access — show a banner with a Settings shortcut.
    case denied
}

/// A single event row shown in the day list / upcoming list. Decoupled from `EKEvent` so the view
/// stays simple and the model is `Sendable`-friendly. `colorComponents` carries the owning
/// calendar's colour so we can draw a coloured dot without holding an `EKEvent`.
public struct CalendarEventItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let calendarColor: CGColor?

    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool,
        calendarColor: CGColor?
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarColor = calendarColor
    }

    /// SwiftUI colour for the owning calendar, falling back to the accent if none is set.
    public var swiftUIColor: Color {
        if let calendarColor {
            return Color(cgColor: calendarColor)
        }
        return .accentColor
    }
}

/// Drives the menu-bar calendar: month navigation, the selected day, and (when permitted) the
/// EventKit-backed event lists. All EventKit access is funnelled through here on the main actor;
/// completion handlers that may run off-main hop back to `@MainActor` before touching any
/// `@Published` state.
@MainActor
public final class CalendarController: ObservableObject {
    /// Year of the currently displayed month.
    @Published public private(set) var displayedYear: Int
    /// Month (1...12) of the currently displayed month.
    @Published public private(set) var displayedMonth: Int
    /// The day the user has selected (defaults to today). Always normalised to midnight.
    @Published public private(set) var selectedDate: Date
    /// Current calendar-access state, drives the permission banner.
    @Published public private(set) var accessState: CalendarAccessState = .notDetermined
    /// Days (midnight Dates) in the visible month that have at least one event — used for grid dots.
    @Published public private(set) var daysWithEvents: Set<Date> = []
    /// Events on the selected day, time-sorted.
    @Published public private(set) var selectedDayEvents: [CalendarEventItem] = []
    /// Events over the next ~7 days, time-sorted.
    @Published public private(set) var upcomingEvents: [CalendarEventItem] = []

    /// The store. Created eagerly; access is gated on `accessState` so an unauthorized store is never
    /// queried for events.
    private let store = EKEventStore()

    /// Calendar used for all date math. Uses the current calendar/timezone so the UI matches the
    /// user's system; `CalendarKit` receives this so the grid respects `firstWeekday`.
    public var calendar: Calendar { Calendar.current }

    public init(today: Date = Date()) {
        let cal = Calendar.current
        let components = cal.dateComponents([.year, .month], from: today)
        displayedYear = components.year ?? 2000
        displayedMonth = components.month ?? 1
        selectedDate = cal.startOfDay(for: today)
        accessState = Self.mapStatus(EKEventStore.authorizationStatus(for: .event))
    }

    // MARK: - Permission

    /// Requests full Calendar access (macOS 14+). The completion handler may run off the main actor,
    /// so we hop back to `@MainActor` before mutating published state or fetching events.
    public func requestAccess() {
        // If already decided, just refresh from the current status and (re)load.
        let current = EKEventStore.authorizationStatus(for: .event)
        if current == .denied || current == .restricted {
            accessState = .denied
            return
        }

        store.requestFullAccessToEvents { [weak self] granted, _ in
            Task { @MainActor in
                guard let self else { return }
                self.accessState = granted ? .authorized : .denied
                if granted {
                    self.reloadEvents()
                }
            }
        }
    }

    /// Re-reads the current authorization status (e.g. after returning from System Settings) and
    /// reloads events if we now have access.
    public func refreshAuthorization() {
        accessState = Self.mapStatus(EKEventStore.authorizationStatus(for: .event))
        if accessState == .authorized {
            reloadEvents()
        }
    }

    // MARK: - Navigation

    public func goToPreviousMonth() {
        shiftMonth(by: -1)
    }

    public func goToNextMonth() {
        shiftMonth(by: 1)
    }

    /// Jumps the displayed month to today's month and selects today.
    public func goToToday() {
        let now = calendar.startOfDay(for: Date())
        let components = calendar.dateComponents([.year, .month], from: now)
        displayedYear = components.year ?? displayedYear
        displayedMonth = components.month ?? displayedMonth
        selectedDate = now
        reloadEvents()
    }

    public func select(_ date: Date) {
        selectedDate = calendar.startOfDay(for: date)
        reloadSelectedDayEvents()
    }

    private func shiftMonth(by delta: Int) {
        var components = DateComponents()
        components.year = displayedYear
        components.month = displayedMonth
        components.day = 1
        guard let firstOfMonth = calendar.date(from: components),
              let shifted = calendar.date(byAdding: .month, value: delta, to: firstOfMonth) else {
            return
        }
        let newComponents = calendar.dateComponents([.year, .month], from: shifted)
        displayedYear = newComponents.year ?? displayedYear
        displayedMonth = newComponents.month ?? displayedMonth
        reloadEvents()
    }

    // MARK: - Grid

    /// The 6×7 grid for the displayed month, respecting the system `firstWeekday`.
    public func monthGrid() -> CalendarKit.MonthGrid {
        CalendarKit.monthGrid(
            year: displayedYear,
            month: displayedMonth,
            firstWeekday: calendar.firstWeekday,
            today: Date(),
            calendar: calendar
        )
    }

    public func weekdaySymbols() -> [String] {
        CalendarKit.weekdaySymbols(firstWeekday: calendar.firstWeekday, calendar: calendar)
    }

    public func monthTitle() -> String {
        CalendarKit.monthTitle(year: displayedYear, month: displayedMonth, calendar: calendar)
    }

    public func isSelected(_ date: Date) -> Bool {
        calendar.isDate(date, inSameDayAs: selectedDate)
    }

    public func hasEvents(on date: Date) -> Bool {
        daysWithEvents.contains(calendar.startOfDay(for: date))
    }

    // MARK: - Event loading

    /// Reloads everything that depends on the visible month + selection. Safe to call when access is
    /// not granted: it simply clears the event lists (the grid still works without permission).
    public func reloadEvents() {
        guard accessState == .authorized else {
            daysWithEvents = []
            selectedDayEvents = []
            upcomingEvents = []
            return
        }
        reloadMonthDots()
        reloadSelectedDayEvents()
        reloadUpcoming()
    }

    private func reloadMonthDots() {
        guard accessState == .authorized else { return }

        var components = DateComponents()
        components.year = displayedYear
        components.month = displayedMonth
        components.day = 1
        guard let monthStart = calendar.date(from: components),
              let dayRange = calendar.range(of: .day, in: .month, for: monthStart),
              let monthEnd = calendar.date(byAdding: .day, value: dayRange.count, to: monthStart) else {
            daysWithEvents = []
            return
        }

        let predicate = store.predicateForEvents(withStart: monthStart, end: monthEnd, calendars: nil)
        let events = store.events(matching: predicate)
        var days: Set<Date> = []
        for event in events {
            days.insert(calendar.startOfDay(for: event.startDate))
        }
        daysWithEvents = days
    }

    private func reloadSelectedDayEvents() {
        guard accessState == .authorized else {
            selectedDayEvents = []
            return
        }

        let dayStart = calendar.startOfDay(for: selectedDate)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            selectedDayEvents = []
            return
        }

        let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
        selectedDayEvents = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map(Self.makeItem(from:))
    }

    private func reloadUpcoming() {
        guard accessState == .authorized else {
            upcomingEvents = []
            return
        }

        let now = Date()
        guard let end = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now)) else {
            upcomingEvents = []
            return
        }

        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        upcomingEvents = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map(Self.makeItem(from:))
    }

    // MARK: - Helpers

    private static func makeItem(from event: EKEvent) -> CalendarEventItem {
        CalendarEventItem(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "(No title)",
            start: event.startDate ?? Date(),
            end: event.endDate ?? event.startDate ?? Date(),
            isAllDay: event.isAllDay,
            calendarColor: event.calendar?.cgColor
        )
    }

    private static func mapStatus(_ status: EKAuthorizationStatus) -> CalendarAccessState {
        switch status {
        case .fullAccess:
            return .authorized
        case .denied, .restricted, .writeOnly:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }
}

/// The floating Calendar popover: a month grid with weekday headers, today highlighting, event
/// dots, prev/next/today navigation, the selected day's events, and an upcoming-events list. The
/// grid works without Calendar permission; events appear once access is granted. Content is scaled
/// to match the menu-bar/display scale so it fits the scaled panel (same approach as the other
/// tools).
public struct CalendarPopoverView: View {
    @StateObject private var controller = CalendarController()
    var onQuit: () -> Void

    private let scale = CalendarSizing.currentScale

    /// A shared time formatter for event start times, built once. Only ever touched on the main
    /// actor (from SwiftUI's `body`), matching the package's other UI formatters.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    public init(onQuit: @escaping () -> Void) {
        self.onQuit = onQuit
    }

    private func s(_ value: CGFloat) -> CGFloat { value * scale }

    private var accent: Color { .red }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)

            if controller.accessState == .denied {
                permissionBanner
            }

            monthHeader
            weekdayHeader
            grid
            Divider().opacity(0.6)
            eventsSection
            footer
        }
        .frame(width: CalendarSizing.preferredSize().width, height: CalendarSizing.preferredSize().height)
        .frostedPanel(cornerRadius: 18)
        .onAppear {
            controller.refreshAuthorization()
            if controller.accessState == .notDetermined {
                controller.requestAccess()
            } else if controller.accessState == .authorized {
                controller.reloadEvents()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: s(8)) {
            Image(systemName: "calendar")
                .font(.system(size: s(15), weight: .semibold))
                .foregroundStyle(accent)

            Text("Calendar")
                .font(.system(size: s(15), weight: .bold))
                .foregroundStyle(.primary.opacity(0.9))

            Spacer()

            Button {
                controller.goToToday()
            } label: {
                Text("Today")
                    .font(.system(size: s(11), weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, s(10))
                    .padding(.vertical, s(4))
                    .background(Capsule().fill(accent))
            }
            .buttonStyle(.plain)
            .help("Jump to today")
        }
        .padding(.horizontal, s(16))
        .padding(.top, s(14))
        .padding(.bottom, s(10))
    }

    // MARK: - Permission banner

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: s(6)) {
            Text("Calendar access needed")
                .font(.system(size: s(12), weight: .semibold))
                .foregroundStyle(.orange)
            Text("Allow DMonte Calendar under Privacy & Security → Calendars to show your events.")
                .font(.system(size: s(11)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Calendar Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            }
            .font(.system(size: s(12), weight: .medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(s(10))
        .background(RoundedRectangle(cornerRadius: s(8)).fill(Color.orange.opacity(0.12)))
        .padding(.horizontal, s(14))
        .padding(.top, s(8))
    }

    // MARK: - Month navigation

    private var monthHeader: some View {
        HStack(spacing: s(10)) {
            navButton(systemImage: "chevron.left", help: "Previous month") {
                controller.goToPreviousMonth()
            }

            Text(controller.monthTitle())
                .font(.system(size: s(14), weight: .bold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)

            navButton(systemImage: "chevron.right", help: "Next month") {
                controller.goToNextMonth()
            }
        }
        .padding(.horizontal, s(16))
        .padding(.top, s(10))
        .padding(.bottom, s(6))
    }

    private func navButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: s(13), weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: s(28), height: s(28))
                .background(Circle().fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Weekday header

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(controller.weekdaySymbols().enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: s(10), weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, s(12))
        .padding(.bottom, s(4))
    }

    // MARK: - Grid

    private var grid: some View {
        let monthGrid = controller.monthGrid()
        return VStack(spacing: s(3)) {
            ForEach(Array(monthGrid.weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: s(3)) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        dayCell(day)
                    }
                }
            }
        }
        .padding(.horizontal, s(12))
        .padding(.bottom, s(8))
    }

    @ViewBuilder
    private func dayCell(_ day: CalendarKit.CalendarDay?) -> some View {
        if let day {
            let selected = controller.isSelected(day.date)
            Button {
                controller.select(day.date)
            } label: {
                VStack(spacing: s(2)) {
                    Text("\(day.day)")
                        .font(.system(size: s(13), weight: day.isToday ? .bold : .medium))
                        .foregroundStyle(dayTextColor(isToday: day.isToday, isSelected: selected))
                    Circle()
                        .fill(controller.hasEvents(on: day.date) ? accent : Color.clear)
                        .frame(width: s(4), height: s(4))
                }
                .frame(maxWidth: .infinity)
                .frame(height: s(34))
                .background(dayBackground(isToday: day.isToday, isSelected: selected))
                .contentShape(RoundedRectangle(cornerRadius: s(7), style: .continuous))
            }
            .buttonStyle(.plain)
        } else {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: s(34))
        }
    }

    private func dayTextColor(isToday: Bool, isSelected: Bool) -> Color {
        if isToday {
            return .white
        }
        if isSelected {
            return accent
        }
        return .primary
    }

    @ViewBuilder
    private func dayBackground(isToday: Bool, isSelected: Bool) -> some View {
        if isToday {
            RoundedRectangle(cornerRadius: s(7), style: .continuous).fill(accent)
        } else if isSelected {
            RoundedRectangle(cornerRadius: s(7), style: .continuous).fill(accent.opacity(0.16))
        } else {
            RoundedRectangle(cornerRadius: s(7), style: .continuous).fill(Color.clear)
        }
    }

    // MARK: - Events

    private var eventsSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: s(10)) {
                eventGroup(title: selectedDayTitle, events: controller.selectedDayEvents, emptyText: "No events")
                eventGroup(title: "Upcoming", events: controller.upcomingEvents, emptyText: "Nothing in the next 7 days")
            }
            .padding(.horizontal, s(14))
            .padding(.vertical, s(10))
        }
        .frame(maxHeight: .infinity)
    }

    private var selectedDayTitle: String {
        let formatter = DateFormatter()
        formatter.calendar = controller.calendar
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: controller.selectedDate)
    }

    @ViewBuilder
    private func eventGroup(title: String, events: [CalendarEventItem], emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: s(5)) {
            Text(title)
                .font(.system(size: s(11), weight: .bold))
                .foregroundStyle(.secondary)

            if controller.accessState != .authorized {
                Text("Grant access to see events.")
                    .font(.system(size: s(11)))
                    .foregroundStyle(.secondary)
            } else if events.isEmpty {
                Text(emptyText)
                    .font(.system(size: s(11)))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(events) { event in
                    eventRow(event)
                }
            }
        }
    }

    private func eventRow(_ event: CalendarEventItem) -> some View {
        HStack(spacing: s(8)) {
            Circle()
                .fill(event.swiftUIColor)
                .frame(width: s(8), height: s(8))

            Text(event.title)
                .font(.system(size: s(12), weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: s(4))

            Text(timeLabel(for: event))
                .font(.system(size: s(10), weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, s(8))
        .padding(.vertical, s(5))
        .background(
            RoundedRectangle(cornerRadius: s(7), style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private func timeLabel(for event: CalendarEventItem) -> String {
        if event.isAllDay {
            return "All day"
        }
        return Self.timeFormatter.string(from: event.start)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                onQuit()
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.system(size: s(12), weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, s(16))
        .padding(.top, s(8))
        .padding(.bottom, s(14))
    }
}
