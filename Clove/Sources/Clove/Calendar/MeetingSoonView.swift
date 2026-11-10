import SwiftUI

/// Beside the notch while a meeting is about to start: its title on the left, a countdown on
/// the right. Hovering opens the island on the calendar page, where the Join button is.
struct MeetingSoonView: View {
    let meeting: UpcomingEvent
    let notchSize: CGSize

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "video.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(meeting.color)
                Text(meeting.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 12)
            .frame(width: IslandLayout.meetingWing, height: notchSize.height, alignment: .leading)

            Color.clear
                .frame(width: notchSize.width, height: notchSize.height)

            // The countdown only changes once a minute; the label is always the current value.
            TimelineView(.everyMinute) { context in
                Text(Self.countdown(to: meeting.start, from: context.date))
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(meeting.start <= context.date ? Color.green : .white.opacity(0.75))
            }
            .padding(.trailing, 12)
            .frame(width: IslandLayout.meetingWing, height: notchSize.height, alignment: .trailing)
        }
    }

    static func countdown(to start: Date, from now: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        return minutes <= 0 ? "Now" : "in \(minutes) min"
    }
}
