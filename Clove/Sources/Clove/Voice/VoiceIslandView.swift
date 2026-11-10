import SwiftUI

/// A voice note inside the expanded island: a live, tagged view while you talk, then a review of
/// the proposed changes. The island is the card,
/// so this view has no chrome of its own. It reports its natural height so the island can hug it.
struct VoiceIslandView: View {
    @ObservedObject var controller: VoiceNoteController
    @ObservedObject private var shortcuts = VoiceShortcutManager.shared
    /// Called with the view's natural height whenever it changes.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 14)
            Divider().opacity(0.5)
            content
                .padding(20)
            footer
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
        .animation(reduceMotion ? nil : Motion.base, value: controller.phase)
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        HStack(spacing: 12) {
            switch controller.phase {
            case .listening:
                RecordingDot()
                Text("Listening")
                    .font(.system(size: 17, weight: .semibold))
                ElapsedTime(since: controller.startedAt)
                Spacer(minLength: 12)
                Waveform(levels: controller.levels)
                if shortcuts.shortcut != .off {
                    KeyCap(shortcuts.shortcut.title)
                }
            case .thinking:
                ProgressView().controlSize(.small)
                Text("Understanding")
                    .font(.system(size: 17, weight: .semibold))
                if let progress = controller.progress, progress.total > 1 {
                    Text("\(min(progress.done + 1, progress.total)) of \(progress.total)")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("On this Mac", systemImage: "lock.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            case .review:
                Image(systemName: "checklist")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.linearAccent)
                Text("Review \(controller.changes.count == 1 ? "1 change" : "\(controller.changes.count) changes")")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
            case .applying:
                ProgressView().controlSize(.small)
                Text("Updating Linear…")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
            case .finished(let message):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: message)
                Text(message)
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Couldn't finish")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
            case .idle:
                EmptyView()
            }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .listening:
            if let progress = controller.preparingProgress {
                ProgressView("Downloading the on-device speech model…", value: progress)
                    .font(.system(size: 13))
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    liveTranscript
                    pickingUp
                }
            }
        case .thinking, .applying:
            VStack(alignment: .leading, spacing: 18) {
                liveTranscript
                pickingUp.opacity(0.55)
            }
        case .review:
            ReviewList(controller: controller)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Text(message)
                    .font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
                if !controller.transcript.isEmpty { liveTranscript }
            }
        case .idle, .finished:
            EmptyView()
        }
    }

    private var liveTranscript: some View {
        ScrollView {
            Group {
                if controller.transcript.isEmpty {
                    Text("Talk through what's on your mind — new things to do, steps for existing work, what you finished. Projects, dates and priorities light up as you say them.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(controller.live.transcript)
                }
            }
            .font(.system(size: 15))
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(maxHeight: 150)
        .fixedSize(horizontal: false, vertical: controller.transcript.count < 280)
        .defaultScrollAnchor(.bottom)
    }

    @ViewBuilder private var pickingUp: some View {
        if !controller.live.drafts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("PICKING UP")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(controller.live.drafts) { draft in
                            DraftRow(draft: draft)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .offset(y: 8)).animation(Motion.base),
                                    removal: .opacity.animation(Motion.fast)))
                        }
                    }
                }
                .frame(maxHeight: 400)
                .fixedSize(horizontal: false, vertical: controller.live.drafts.count <= 6)
                .defaultScrollAnchor(.bottom)
            }
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        switch controller.phase {
        case .listening:
            HStack {
                Button("Cancel", role: .cancel) { controller.cancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    Task { await controller.finishListening() }
                } label: {
                    Label("Done", systemImage: "stop.fill")
                        .padding(.horizontal, 6)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        case .review:
            HStack {
                Button("Cancel", role: .cancel) { controller.cancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    Task { await controller.apply() }
                } label: {
                    Text(controller.selectedCount == 1 ? "Apply 1 change" : "Apply \(controller.selectedCount) changes")
                        .padding(.horizontal, 6)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.linearAccent)
                .disabled(controller.selectedCount == 0)
            }
        case .failed:
            HStack {
                Button("Close", role: .cancel) { controller.cancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Try Again") { Task { await controller.start() } }
                    .keyboardShortcut(.defaultAction)
            }
        case .thinking, .applying:
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { controller.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        case .idle, .finished:
            EmptyView()
        }
    }
}

// MARK: - Task cards

/// The shared look of a task: a rounded card with the title on top and its chips underneath.
private struct TaskCard<Title: View, Chips: View, Accessory: View>: View {
    var dimmed = false
    /// A drop target: outlined in the accent color.
    var highlighted = false
    @ViewBuilder let title: Title
    @ViewBuilder let chips: Chips
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 9) {
                title
                FlowLayout(spacing: 6) { chips }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(highlighted ? Color.linearAccent.opacity(0.12) : Color.primary.opacity(dimmed ? 0.025 : 0.055),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(highlighted ? Color.linearAccent : Color.primary.opacity(0.07), lineWidth: highlighted ? 2 : 1))
        .opacity(dimmed ? 0.55 : 1)
    }
}

/// A task heard while talking, with its live chips.
private struct DraftRow: View {
    let draft: LiveDraft

    var body: some View {
        TaskCard {
            HStack(spacing: 6) {
                if draft.kind == .bundle {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(Color.linearAccent)
                }
                Text(draft.title)
                    .lineLimit(2)
            }
            .font(.system(size: 14.5, weight: .semibold))
        } chips: {
            ForEach(draft.tags) { TagChip(tag: $0) }
        } accessory: {
            EmptyView()
        }
    }
}

// MARK: - Review list with drag and drop

private enum DropZone: Equatable {
    /// Onto the card: the two tasks become one.
    case merge
    /// Onto its lower edge: it becomes a sub-task.
    case subtask
}

private struct DropHover: Equatable {
    let id: UUID
    let zone: DropZone
}

/// The proposed changes, rearranged by dragging: drop a new task onto another to merge them,
/// onto a card's lower edge to make it a sub-task, or on the bottom zone to take it back out.
private struct ReviewList: View {
    @ObservedObject var controller: VoiceNoteController
    @State private var dragging: UUID?
    @State private var hover: DropHover?
    /// Card heights while not hovered, to tell the merge area from the sub-task edge.
    @State private var heights: [UUID: CGFloat] = [:]
    @State private var mouseMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Drag a task onto another to merge them, or onto its lower edge to make it a sub-task. Double-click a title to rename.",
                  systemImage: "hand.draw")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // At the top, where it's always in view while a sub-task is being dragged.
                    if let dragging, let change = controller.changes.first(where: { $0.id == dragging }),
                       VoicePlanner.isNested(change, in: controller.changes) {
                        DropSlot(text: "Drop here to make it a separate task", symbol: "arrow.uturn.left", isTargeted: hover == nil)
                            .onDrop(of: [.text], delegate: SeparateDrop(controller: controller, dragging: $dragging))
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    ForEach($controller.changes) { $change in
                        row(for: $change)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)  // room for the "Merge" badge above the first card
                .padding(.bottom, 2)
            }
            .frame(maxHeight: 440)
        }
        .animation(Motion.snappy, value: hover)
        .animation(Motion.snappy, value: controller.changes.map(\.id))
        .animation(Motion.snappy, value: dragging)
        .onAppear(perform: watchForCancelledDrags)
        .onDisappear {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        }
    }

    @ViewBuilder private func row(for change: Binding<ProposedChange>) -> some View {
        let id = change.wrappedValue.id
        let nested = VoicePlanner.isNested(change.wrappedValue, in: controller.changes)
        let zone = hover?.id == id ? hover?.zone : nil
        VStack(alignment: .leading, spacing: 6) {
            ChangeRow(
                change: change,
                highlighted: zone == .merge,
                isMerging: controller.merging.contains(id),
                isDragging: dragging == id
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if hover?.id != id { heights[id] = height }
            }
            if zone == .subtask {
                DropSlot(text: "Add as a sub-task", symbol: "arrow.turn.down.right", isTargeted: true)
                    .padding(.leading, 26)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .draggableTask(change.wrappedValue.isNew) {
            dragging = id
            return NSItemProvider(object: id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: CardDrop(target: id, height: heights[id] ?? 80, controller: controller,
                                                dragging: $dragging, hover: $hover))
        .padding(.leading, nested ? 26 : 0)
        .overlay(alignment: .topLeading) {
            if nested { SubtaskConnector() }
        }
    }

    /// A drag dropped outside any target (or cancelled) never reports back, so clear it once
    /// the mouse moves with no button held.
    private func watchForCancelledDrags() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp]) { event in
            if NSEvent.pressedMouseButtons == 0, dragging != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    if NSEvent.pressedMouseButtons == 0 {
                        dragging = nil
                        hover = nil
                    }
                }
            }
            return event
        }
    }
}

/// Decides merge vs. sub-task from where over the card the drag is, and carries it out.
private struct CardDrop: DropDelegate {
    let target: UUID
    let height: CGFloat
    let controller: VoiceNoteController
    @Binding var dragging: UUID?
    @Binding var hover: DropHover?

    private func zone(_ info: DropInfo) -> DropZone? {
        guard let source = dragging else { return nil }
        let canMerge = MainActor.assumeIsolated { controller.canMerge(source, into: target) }
        let canNest = MainActor.assumeIsolated { controller.canNest(source, under: target) }
        // The lower edge of the card (and the slot that opens below it) makes a sub-task.
        let onLowerEdge = info.location.y > height - min(34, height * 0.4)
        if canNest, onLowerEdge || !canMerge { return .subtask }
        return canMerge ? .merge : nil
    }

    func validateDrop(info: DropInfo) -> Bool { zone(info) != nil }

    func dropEntered(info: DropInfo) {
        hover = zone(info).map { DropHover(id: target, zone: $0) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let zone = zone(info)
        let next = zone.map { DropHover(id: target, zone: $0) }
        if next != hover { hover = next }
        return DropProposal(operation: zone == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        if hover?.id == target { hover = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let source = dragging, let zone = zone(info) else { return false }
        hover = nil
        dragging = nil
        MainActor.assumeIsolated {
            switch zone {
            case .merge: Task { await controller.merge(source, into: target) }
            case .subtask: controller.makeSubtask(source, of: target)
            }
        }
        return true
    }
}

/// The zone that takes a sub-task back out from under its parent.
private struct SeparateDrop: DropDelegate {
    let controller: VoiceNoteController
    @Binding var dragging: UUID?

    func performDrop(info: DropInfo) -> Bool {
        guard let source = dragging else { return false }
        dragging = nil
        MainActor.assumeIsolated { controller.makeSeparate(source) }
        return true
    }
}

/// A dashed slot showing where a dragged task will land.
private struct DropSlot: View {
    let text: String
    let symbol: String
    var isTargeted = false

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(isTargeted ? Color.linearAccent : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(Color.linearAccent.opacity(isTargeted ? 0.10 : 0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isTargeted ? Color.linearAccent : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
    }
}

private extension View {
    /// Only new tasks can be dragged; changes to existing issues stay put.
    @ViewBuilder func draggableTask(_ enabled: Bool, start: @escaping () -> NSItemProvider) -> some View {
        if enabled { onDrag(start) } else { self }
    }
}

/// One proposed change as a card. A new task's title is renamed by double-clicking it.
private struct ChangeRow: View {
    @Binding var change: ProposedChange
    var highlighted = false
    var isMerging = false
    var isDragging = false
    @State private var isEditing = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        TaskCard(dimmed: !change.isSelected, highlighted: highlighted) {
            VStack(alignment: .leading, spacing: 4) {
                if change.isNew, isEditing {
                    TextField("Title", text: $change.title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14.5, weight: .semibold))
                        .focused($titleFocused)
                        .onSubmit { isEditing = false }
                        .onChange(of: titleFocused) { _, focused in if !focused { isEditing = false } }
                        .onAppear { titleFocused = true }
                } else {
                    Text(change.headline)
                        .font(.system(size: 14.5, weight: .semibold))
                        .lineLimit(2)
                        .onTapGesture(count: 2) { if change.isNew { isEditing = true } }
                }
                if let comment = change.comment {
                    Text("“\(comment)”")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let duplicate = change.possibleDuplicate {
                    Label("Looks like “\(duplicate.title)” already exists", systemImage: "square.on.square")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
            }
        } chips: {
            ForEach(change.tags) { TagChip(tag: $0) }
        } accessory: {
            if isMerging {
                ProgressView().controlSize(.small)
            } else {
                SelectionCheck(isOn: $change.isSelected)
            }
        }
        .overlay(alignment: .top) {
            if highlighted {
                Label("Merge into one task", systemImage: "arrow.triangle.merge")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.linearAccent, in: Capsule())
                    .offset(y: -10)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .opacity(isDragging ? 0.35 : 1)
        .scaleEffect(isDragging ? 0.98 : 1)
        .contentShape(Rectangle())
    }
}

/// A round check in the card's corner: whether this change will be applied.
private struct SelectionCheck: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(isOn ? Color.linearAccent : Color.secondary.opacity(0.6))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(isOn ? "Will be applied" : "Skipped")
    }
}

/// The elbow line linking a sub-task to its parent card above.
private struct SubtaskConnector: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 11, y: -8))
            path.addLine(to: CGPoint(x: 11, y: 18))
            path.addQuadCurve(to: CGPoint(x: 22, y: 26), control: CGPoint(x: 11, y: 26))
        }
        .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        .frame(width: 26, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Building blocks

/// A soft, tinted rounded chip with a hairline border in the same hue. Status, urgency and
/// comments are icon-only (with the name as a tooltip).
struct TagChip: View {
    let tag: VoiceTag
    /// Overrides the tag's own icon.
    var symbol: String?
    var showsDisclosure = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol ?? tag.symbol)
                .font(.system(size: tag.iconOnly ? 12 : 10.5, weight: .semibold))
            if !tag.iconOnly {
                Text(tag.text)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            if showsDisclosure {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.7)
            }
        }
        .foregroundStyle(tag.color)
        .padding(.horizontal, tag.iconOnly ? 6 : 8)
        .frame(minWidth: tag.iconOnly ? 26 : nil, minHeight: 24)
        .background(tag.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(tag.color.opacity(0.22), lineWidth: 0.75))
        .help(tag.text)
    }
}

/// A pulsing red dot while recording.
private struct RecordingDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(.red.opacity(0.5), lineWidth: 6).scaleEffect(pulsing ? 1.6 : 0.8).opacity(pulsing ? 0 : 1))
            .onAppear {
                Motion.perform(Motion.pulse) { pulsing = true }
            }
    }
}

private struct ElapsedTime: View {
    let since: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = since.map { max(0, Int(context.date.timeIntervalSince($0))) } ?? 0
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// Live microphone bars, newest on the right.
private struct Waveform: View {
    let levels: [Double]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(LinearGradient(colors: [.red.opacity(0.85), Color.linearAccent], startPoint: .bottom, endPoint: .top))
                    .frame(width: 3, height: 3 + levels[index] * 22)
                    .opacity(0.35 + 0.65 * Double(index) / Double(max(levels.count - 1, 1)))
            }
        }
        .frame(height: 26)
        .animation(Motion.liveSignal, value: levels)
    }
}

private struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.3), lineWidth: 0.5))
    }
}

/// Lays chips out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
