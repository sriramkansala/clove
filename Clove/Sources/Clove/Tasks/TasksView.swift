import SwiftUI

/// The tasks page, "This Week": the active cycle's issues grouped under
/// their workflow state, each with its priority and status glyphs and title. A few rows first;
/// "View more" grows the list in place (scrolling when it gets long).
struct TasksView: View {
    @ObservedObject var linear: LinearService
    let expanded: Bool
    let onViewMore: () -> Void

    var body: some View {
        if case .failed(let message) = linear.status {
            MessageView(symbol: "exclamationmark.triangle", text: message)
        } else if linear.issues.isEmpty {
            MessageView(symbol: "checkmark.circle", text: "Nothing left this week")
        } else if expanded {
            ScrollView(.vertical, showsIndicators: false) {
                groupsView(TaskGroup.make(from: linear.issues), viewMore: false)
            }
        } else {
            let groups = TaskGroup.make(from: linear.issues, rowBudget: IslandLayout.compactTaskRows)
            groupsView(groups, viewMore: TaskGroup.issueCount(groups) < linear.issues.count)
        }
    }

    private func groupsView(_ groups: [TaskGroup], viewMore: Bool) -> some View {
        let lastID = groups.last?.issues.last?.id
        return VStack(alignment: .leading, spacing: IslandLayout.taskGroupSpacing) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: IslandLayout.taskRowSpacing) {
                    Text(group.name)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(height: IslandLayout.taskHeaderHeight)
                    ForEach(group.issues) { issue in
                        HStack(spacing: 8) {
                            Button(action: { linear.open(issue) }) {
                                IssueRow(issue: issue)
                            }
                            .buttonStyle(.pressable(.subtle))

                            if viewMore && issue.id == lastID {
                                ViewMoreButton(action: onViewMore)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IssueRow: View {
    let issue: LinearIssue

    var body: some View {
        HStack(spacing: 6) {
            PriorityIcon(priority: issue.priority)
            StatusIcon(type: issue.stateType, color: Color(linearState: issue.stateColor))
            Text(issue.title)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: IslandLayout.taskRowHeight)
        .contentShape(Rectangle())
    }
}

/// Linear's status glyphs: dashed ring = backlog/triage, ring = todo, half-filled = in progress.
private struct StatusIcon: View {
    let type: String
    let color: Color

    var body: some View {
        ZStack {
            switch type {
            case "backlog", "triage":
                Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [1.6, 1.6]))
            case "started":
                Circle().strokeBorder(color, lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: 0.5)
                    .stroke(color, lineWidth: 4.5)
                    .frame(width: 4.5, height: 4.5)
                    .rotationEffect(.degrees(-90))
            default:
                Circle().strokeBorder(color, lineWidth: 1.5)
            }
        }
        .frame(width: 12, height: 12)
    }
}

/// Linear's priority glyphs: urgent = orange "!" square, high/medium/low = 3/2/1 signal bars,
/// none = "…".
private struct PriorityIcon: View {
    let priority: Int

    var body: some View {
        Group {
            switch priority {
            case 1:
                Image(systemName: "exclamationmark.square.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            case 2, 3, 4:
                PriorityBars(filled: 5 - priority)
            default:
                Image(systemName: "ellipsis")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .frame(width: 12, height: 12)
    }
}

private struct PriorityBars: View {
    /// 3 = high, 2 = medium, 1 = low.
    let filled: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.2) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.6)
                    .fill(Color.white.opacity(index < filled ? 0.6 : 0.18))
                    .frame(width: 2.4, height: 4 + CGFloat(index) * 2.5)
            }
        }
    }
}

private struct ViewMoreButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("View more")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))
                .padding(.horizontal, 8)
                .frame(height: IslandLayout.taskRowHeight)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.12)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(.normal, hoverWash: false))
    }
}

private extension Color {
    /// Linear's "#rrggbb" state colours, on the island's black: very dark ones would vanish,
    /// so they fall back to a light grey.
    init(linearState hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = .white.opacity(0.6)
            return
        }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        if 0.299 * red + 0.587 * green + 0.114 * blue < 0.25 {
            self = .white.opacity(0.6)
            return
        }
        self = Color(red: red, green: green, blue: blue)
    }
}
