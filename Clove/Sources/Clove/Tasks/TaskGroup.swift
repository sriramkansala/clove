import CoreGraphics

/// Issues under one workflow state ("In Progress", "Todo", …), as Linear groups them.
struct TaskGroup: Identifiable {
    let name: String
    let issues: [LinearIssue]
    var id: String { name }

    /// Groups already-sorted issues by state, in the order the states first appear, keeping at
    /// most `rowBudget` rows where each state heading counts as a row.
    static func make(from issues: [LinearIssue], rowBudget: Int = .max) -> [TaskGroup] {
        var order: [String] = []
        var byState: [String: [LinearIssue]] = [:]
        for issue in issues {
            if byState[issue.stateName] == nil { order.append(issue.stateName) }
            byState[issue.stateName, default: []].append(issue)
        }

        var groups: [TaskGroup] = []
        var usedRows = 0
        for name in order {
            let available = rowBudget - usedRows - 1
            guard available > 0, let members = byState[name] else { break }
            let visible = Array(members.prefix(available))
            groups.append(TaskGroup(name: name, issues: visible))
            usedRows += 1 + visible.count
        }
        return groups
    }

    static func issueCount(_ groups: [TaskGroup]) -> Int {
        groups.reduce(0) { $0 + $1.issues.count }
    }

    /// Height of `groups` as `TasksView` lays them out; one message line when empty.
    static func height(of groups: [TaskGroup]) -> CGFloat {
        guard !groups.isEmpty else { return IslandLayout.messageHeight }
        let blocks = groups.map { group in
            IslandLayout.taskHeaderHeight
                + CGFloat(group.issues.count) * (IslandLayout.taskRowSpacing + IslandLayout.taskRowHeight)
        }
        return blocks.reduce(0, +) + CGFloat(groups.count - 1) * IslandLayout.taskGroupSpacing
    }
}
