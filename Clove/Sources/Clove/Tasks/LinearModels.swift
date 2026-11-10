import Foundation

/// The viewer's open Linear issues and the active cycle.
struct LinearSnapshot: Codable, Equatable {
    var viewerName: String
    var issues: [LinearIssue]
    var cycle: CycleSummary?
    var fetchedAt: Date
}

struct LinearIssue: Codable, Equatable, Identifiable {
    var id: String
    var identifier: String
    var title: String
    var url: URL
    /// 0 = none, 1 = urgent, 2 = high, 3 = medium, 4 = low.
    var priority: Int
    var stateName: String
    /// Linear workflow state type: triage, backlog, unstarted, started.
    var stateType: String
    var stateColor: String
    var statePosition: Double
    var teamKey: String
    /// "yyyy-MM-dd", or nil when the issue has no due date.
    var dueDate: String?
    var inCurrentCycle: Bool
    /// In a cycle that hasn't started yet.
    var inUpcomingCycle: Bool
    var projectID: String? = nil
    var projectName: String? = nil

    /// Matches the order Linear uses on "My issues": in progress first, backlog last.
    var stateRank: Int {
        switch stateType {
        case "started": 0
        case "unstarted": 1
        case "triage": 2
        case "backlog": 3
        default: 4
        }
    }

    /// Urgent first, "no priority" last.
    var priorityRank: Int { priority == 0 ? 5 : priority }
}

struct CycleSummary: Codable, Equatable {
    var teamName: String
    var teamKey: String
    var number: Int
    var name: String?
    var startsAt: Date
    var endsAt: Date
    /// 0...1, as reported by Linear (completed scope / total scope).
    var progress: Double

    var title: String {
        if let name, !name.isEmpty { return name }
        return "Cycle \(number)"
    }
}

struct LinearTeam: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var key: String
    var hasActiveCycle: Bool
}

extension LinearIssue {
    /// The due date as local midnight, from Linear's "yyyy-MM-dd".
    var dueDay: Date? {
        guard let dueDate else { return nil }
        let parts = dueDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    func isOverdue(at date: Date = Date()) -> Bool {
        guard let dueDay else { return false }
        return dueDay < Calendar.current.startOfDay(for: date)
    }

    func isDueToday(at date: Date = Date()) -> Bool {
        guard let dueDay else { return false }
        return Calendar.current.isDate(dueDay, inSameDayAs: date)
    }
}
