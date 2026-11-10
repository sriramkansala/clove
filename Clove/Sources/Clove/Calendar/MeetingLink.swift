import EventKit
import Foundation

/// Finds a video-call link in a calendar event: its URL field first, then its location and
/// notes, where invitations from Google, Microsoft and Zoom put the link.
enum MeetingLink {
    /// Hosts (and their subdomains) that serve joinable meetings.
    private static let meetingHosts = [
        "zoom.us", "zoom.com", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "facetime.apple.com", "whereby.com", "around.co", "gotomeeting.com",
        "chime.aws", "meet.jit.si",
    ]

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func find(in event: EKEvent) -> URL? {
        if let url = event.url, isMeeting(url) {
            return url
        }
        for text in [event.location, event.notes].compactMap({ $0 }) where !text.isEmpty {
            if let url = firstMeetingURL(in: text) {
                return url
            }
        }
        return nil
    }

    private static func firstMeetingURL(in text: String) -> URL? {
        let range = NSRange(text.startIndex..., in: text)
        return detector?.matches(in: text, range: range)
            .compactMap(\.url)
            .first(where: isMeeting)
    }

    /// Schemes that open a meeting app directly (Zoom, Teams, Webex).
    private static let appSchemes: Set<String> = ["zoommtg", "zoomus", "msteams", "webex"]

    private static func isMeeting(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if appSchemes.contains(scheme) { return true }
        guard scheme == "https" || scheme == "http", let host = url.host?.lowercased() else { return false }
        return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
