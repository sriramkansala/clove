import SwiftUI

/// The calendar page: up to `IslandLayout.maxEvents` upcoming events, or one quiet line.
struct CalendarColumnView: View {
    @ObservedObject var calendar: CalendarService

    var body: some View {
        switch calendar.access {
        case .notDetermined:
            Button(action: { calendar.requestAccess() }) {
                MessageView(symbol: "calendar", text: "Show calendar")
            }
            .buttonStyle(.pressable(.subtle))

        case .denied:
            EmptyView()

        case .granted where calendar.events.isEmpty:
            TodayView()

        case .granted:
            VStack(alignment: .leading, spacing: IslandLayout.eventRowSpacing) {
                ForEach(calendar.events.prefix(IslandLayout.maxEvents)) { event in
                    EventRow(event: event, join: { calendar.join(event) })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Today's date, shown when there are no more events: the weekday in white, the rest quieter.
/// Re-renders every minute so it turns over at midnight.
private struct TodayView: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 5) {
                Text(context.date, format: .dateTime.weekday(.wide))
                    .foregroundColor(.white)
                    .fontWeight(.semibold)
                Text(context.date, format: .dateTime.day().month(.wide))
                    .foregroundColor(.white.opacity(0.55))
            }
            .font(.system(size: 13))
            .frame(maxWidth: .infinity)
            .frame(height: IslandLayout.messageHeight)
        }
    }
}

private struct EventRow: View {
    let event: UpcomingEvent
    let join: () -> Void

    var body: some View {
        // Re-evaluated each minute so Join appears when the meeting comes within reach.
        TimelineView(.everyMinute) { context in
            HStack(spacing: 8) {
                Capsule()
                    .fill(event.color)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                    Text(timeText)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundColor(.white.opacity(0.55))
                }
                .lineLimit(1)

                Spacer(minLength: 8)

                if event.isMeeting {
                    JoinButton(prominent: CalendarService.isJoinable(event, at: context.date), action: join)
                }
            }
            .frame(height: IslandLayout.eventRowHeight)
        }
    }

    private var timeText: String {
        if event.isAllDay { return "All day" }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        let prefix = Calendar.current.isDateInTomorrow(event.start) ? "Tomorrow " : ""
        return "\(prefix)\(start) – \(end)"
    }
}

/// Opens the call. Green when the meeting is about to start (or just started), quiet grey for
/// meetings further out, so the one that matters now stands out.
private struct JoinButton: View {
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Join", systemImage: "video.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(prominent ? .white : .white.opacity(0.8))
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(Capsule().fill(prominent ? Color.green.opacity(0.85) : Color.white.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.pressable(.normal, hoverWash: false))
        .accessibilityHint("Opens the meeting link")
    }
}
