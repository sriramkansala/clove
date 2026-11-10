import AppKit
import EventKit
import SwiftUI

struct UpcomingEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let color: Color
    /// Video-call link found in the event (Zoom, Meet, Teams, Webex, FaceTime, …), if any.
    let joinURL: URL?

    var isMeeting: Bool { joinURL != nil }
}

/// Upcoming events from the user's calendars (now until the end of tomorrow, at most `IslandLayout.maxEvents`).
/// Access is only requested from a button in the expanded island, never at launch.
@MainActor
final class CalendarService: ObservableObject {
    enum Access { case notDetermined, granted, denied }

    @Published private(set) var access: Access
    @Published private(set) var events: [UpcomingEvent] = []
    /// The next meeting with a join link, from `meetingLeadTime` before it starts until
    /// `meetingGrace` after; drives the "meeting soon" activity beside the notch.
    @Published private(set) var imminentMeeting: UpcomingEvent?

    static let meetingLeadTime: TimeInterval = 10 * 60
    static let meetingGrace: TimeInterval = 10 * 60

    /// Every upcoming event in the window, not just the ones shown: a meeting can be imminent
    /// while earlier, non-meeting events fill the visible rows.
    private var upcoming: [UpcomingEvent] = []
    private var clockTimer: Timer?

    private let store = EKEventStore()
    private var refreshTimer: Timer?
    private var storeObserver: NSObjectProtocol?

    init() {
        access = Self.currentAccess()
        if access == .granted {
            startUpdating()
        }
    }

    func requestAccess() {
        guard access == .notDetermined else { return }
        Task {
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            access = granted ? .granted : .denied
            if granted {
                startUpdating()
            }
        }
    }

    func refresh() {
        guard access == .granted else { return }
        let now = Date()
        let calendar = Calendar.current
        guard let end = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) else { return }

        // The predicate also returns events already in progress at `now`.
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        upcoming = store.events(matching: predicate)
            .filter { $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                UpcomingEvent(
                    id: "\(event.calendarItemIdentifier)-\(event.startDate.timeIntervalSince1970)",
                    title: event.title ?? "",
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    color: Color(nsColor: event.calendar.color),
                    joinURL: event.isAllDay ? nil : MeetingLink.find(in: event)
                )
            }
        // Timed events first: all-day ones start at midnight and would otherwise take the rows
        // a meeting needs.
        let visible = Array((upcoming.filter { !$0.isAllDay } + upcoming.filter(\.isAllDay))
            .prefix(IslandLayout.maxEvents))
        if visible != events {
            events = visible
        }
        updateImminentMeeting()
    }

    /// Whether `event` is close enough to its start (or just started) to offer Join.
    static func isJoinable(_ event: UpcomingEvent, at date: Date = Date()) -> Bool {
        guard event.isMeeting else { return false }
        let untilStart = event.start.timeIntervalSince(date)
        return untilStart <= meetingLeadTime && date < event.end && -untilStart <= meetingGrace
    }

    func join(_ event: UpcomingEvent) {
        guard let url = event.joinURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Cheap and frequent: re-evaluates the already-fetched events against the clock.
    private func updateImminentMeeting() {
        let now = Date()
        let next = upcoming.first { Self.isJoinable($0, at: now) }
        if next != imminentMeeting {
            imminentMeeting = next
        }
    }

    private func startUpdating() {
        refresh()
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        // The meeting window opens and closes with the clock, between fetches.
        let clock = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateImminentMeeting() }
        }
        RunLoop.main.add(clock, forMode: .common)
        clockTimer = clock
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied  // denied, restricted, or write-only
        }
    }
}
