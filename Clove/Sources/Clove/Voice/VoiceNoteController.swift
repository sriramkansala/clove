import AppKit
import SwiftUI

/// Drives one voice note: listen (with live tagging) → understand → review → apply. The note
/// plays out inside the expanded island: `onPresent` opens and pins it, and the island lets it go
/// when `phase` returns to idle.
@MainActor
final class VoiceNoteController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case review
        case applying
        case finished(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""
    @Published var changes: [ProposedChange] = []
    /// Projects offered in the review picker for new tasks.
    @Published private(set) var catalog = VoiceCatalog()
    /// Set while the on-device speech model downloads on first use.
    @Published private(set) var preparingProgress: Double?
    /// The transcript with its tagged words highlighted, and the tasks heard so far.
    @Published private(set) var live = LiveTagging()
    /// Recent microphone levels (0...1), oldest first, for the waveform.
    @Published private(set) var levels = Array(repeating: 0.0, count: VoiceNoteController.levelCount)
    @Published private(set) var startedAt: Date?
    /// While understanding: requests decided and total.
    @Published private(set) var progress: (done: Int, total: Int)?

    /// The island shows and pins itself for the note.
    var onPresent: (() -> Void)?

    static let levelCount = 32
    /// Recordings stop on their own after this long; brain dumps can run a while.
    private static let maxDuration: Duration = .seconds(300)
    private static let catalogKey = "voiceCatalog"

    private let linear: LinearService
    private let recorder = SpeechRecorder()
    /// Fresh issues and team IDs, loaded while the user is still talking.
    private var preparation: Task<(LinearSnapshot, LinearWriter.Context), Error>?
    private var autoStop: Task<Void, Never>?
    private var retag: Task<Void, Never>?
    /// Issues the live tagger matches against: cached at first, fresh once loaded.
    private var liveIssues: [LinearIssue] = []

    var selectedCount: Int { changes.filter(\.isSelected).count }
    /// Merges being written by the model, by the target card's ID.
    @Published private(set) var merging: Set<UUID> = []

    init(linear: LinearService) {
        self.linear = linear
    }

    // MARK: - Rearranging in review

    /// Whether `source` can be merged into `target`: two different new tasks, not parent and child.
    func canMerge(_ source: UUID, into target: UUID) -> Bool {
        guard source != target, let a = change(source), let b = change(target), a.isNew, b.isNew else { return false }
        return a.parentChangeID != target && b.parentChangeID != source
    }

    /// Whether `source` can become a sub-task of `target`.
    func canNest(_ source: UUID, under target: UUID) -> Bool {
        guard source != target, let a = change(source), let b = change(target), a.isNew else { return false }
        return b.parentChangeID != source && a.parentChangeID != (b.parentChangeID ?? b.id)
    }

    /// Drops `source` under `target`. Sub-tasks stay one level deep: dropping onto a sub-task makes
    /// a sibling under the same parent, and the moved task's own sub-tasks come along beside it.
    func makeSubtask(_ source: UUID, of target: UUID) {
        guard canNest(source, under: target), let targetChange = change(target) else { return }
        let parentChangeID: UUID? = targetChange.parentChangeID ?? (targetChange.isNew ? targetChange.id : nil)
        let parentIssue: LinearIssue? = parentChangeID == nil ? targetChange.existing : nil
        for index in changes.indices where changes[index].id == source || changes[index].parentChangeID == source {
            changes[index].parentChangeID = parentChangeID
            changes[index].parent = parentIssue
            changes[index].isSelected = true
        }
        changes = VoicePlanner.ordered(changes)
    }

    /// Takes a sub-task out from under its parent.
    func makeSeparate(_ id: UUID) {
        guard let index = changes.firstIndex(where: { $0.id == id }), changes[index].isNew else { return }
        changes[index].parentChangeID = nil
        changes[index].parent = nil
        changes = VoicePlanner.ordered(changes)
    }

    /// Folds `source` into `target`: one task with a combined title, the earlier due date, the higher
    /// priority, both descriptions and both sets of labels and sub-tasks.
    func merge(_ source: UUID, into target: UUID) async {
        guard canMerge(source, into: target), let a = change(target), let b = change(source) else { return }
        merging.insert(target)
        let title = await VoicePlanner.mergedTitle(a.title, b.title)
        merging.remove(target)
        guard phase == .review, let index = changes.firstIndex(where: { $0.id == target }), change(source) != nil else { return }

        var merged = changes[index]
        merged.title = title
        merged.dueDate = [a.dueDate, b.dueDate].compactMap { $0 }.min()
        merged.priority = [a.priority, b.priority].compactMap { $0 }.min()
        merged.labels = a.labels + b.labels.filter { label in !a.labels.contains(label) }
        merged.summary = [a.summary, b.summary].compactMap { $0 }.joined(separator: "\n\n")
        if merged.status == .unchanged { merged.status = b.status }
        if merged.placement == .unchanged { merged.placement = b.placement }
        merged.possibleDuplicate = nil
        merged.isSelected = true
        changes[index] = merged
        for child in changes.indices where changes[child].parentChangeID == source {
            changes[child].parentChangeID = target
        }
        changes.removeAll { $0.id == source }
        changes = VoicePlanner.ordered(changes)
    }

    private func change(_ id: UUID) -> ProposedChange? {
        changes.first { $0.id == id }
    }

    /// The shortcut and the island's mic button both land here.
    func toggle() {
        switch phase {
        case .idle, .finished, .failed: Task { await start() }
        case .listening: Task { await finishListening() }
        case .review: onPresent?()
        case .thinking, .applying: break
        }
    }

    func start() async {
        transcript = ""
        changes = []
        live = LiveTagging()
        levels = Array(repeating: 0, count: Self.levelCount)
        progress = nil
        startedAt = nil
        liveIssues = linear.snapshot?.issues ?? []
        catalog = Self.cachedCatalog() ?? VoiceCatalog()
        phase = .listening
        onPresent?()

        guard let apiKey = linear.apiKey else {
            return fail("Connect Linear in Clove's Settings first.")
        }
        if let reason = VoicePlanner.unavailableReason { return fail(reason) }

        // Fresh issues, projects and labels load while the user is talking.
        let preparation = Task {
            let writer = LinearWriter(apiKey: apiKey)
            async let snapshot = LinearClient(apiKey: apiKey).fetch(preferredTeamID: nil)
            async let context = writer.loadContext()
            return try await (snapshot.snapshot, context)
        }
        self.preparation = preparation
        Task { [weak self] in
            guard let (snapshot, context) = try? await preparation.value, let self else { return }
            self.liveIssues = snapshot.issues
            self.catalog = context.catalog(defaultTeamKey: snapshot.cycle?.teamKey)
            Self.cache(self.catalog)
            self.scheduleRetag()
        }

        do {
            try await SpeechRecorder.requestPermission()
            recorder.onTranscript = { [weak self] text in
                self?.transcript = text
                self?.scheduleRetag()
            }
            recorder.onPreparing = { [weak self] in self?.preparingProgress = $0 }
            recorder.onLevel = { [weak self] level in
                guard let self else { return }
                self.levels = Array(self.levels.dropFirst()) + [level]
            }
            try await recorder.start(vocabulary: Self.vocabulary(catalog: catalog, issues: liveIssues))
            preparingProgress = nil
            startedAt = Date()
        } catch {
            preparingProgress = nil
            return fail(error.localizedDescription)
        }
        guard phase == .listening else { return recorder.cancel() }  // cancelled while starting
        autoStop = Task { [weak self] in
            try? await Task.sleep(for: Self.maxDuration)
            guard !Task.isCancelled, self?.phase == .listening else { return }
            await self?.finishListening()
        }
    }

    func finishListening() async {
        guard phase == .listening else { return }
        autoStop?.cancel()
        phase = .thinking
        let text = await recorder.stop()
        transcript = text
        live = LiveTagger.tag(text, issues: liveIssues, catalog: catalog)
        guard !text.isEmpty else { return fail("Didn't catch anything. Try again a little closer to the mic.") }

        do {
            guard let preparation else { return fail("Couldn't reach Linear.") }
            let (snapshot, context) = try await preparation.value
            linear.adopt(snapshot)
            catalog = context.catalog(defaultTeamKey: snapshot.cycle?.teamKey)
            let planned = try await VoicePlanner().plan(
                transcript: text, issues: snapshot.issues, catalog: catalog, cycleEnd: snapshot.cycle?.endsAt,
                onProgress: { [weak self] done, total in
                    Task { @MainActor in self?.progress = (done, total) }
                }
            )
            guard phase == .thinking else { return }  // cancelled meanwhile
            changes = planned
            phase = planned.isEmpty ? .failed("Nothing to change in Linear from that note.") : .review
        } catch {
            if phase == .thinking { fail(error.localizedDescription) }
        }
    }

    func apply() async {
        let selected = changes.filter(\.isSelected)
        guard !selected.isEmpty, let apiKey = linear.apiKey, let preparation else { return }
        phase = .applying
        do {
            let (_, context) = try await preparation.value
            let count = try await LinearWriter(apiKey: apiKey).apply(selected, context: context)
            linear.refresh()
            guard phase == .applying else { return }
            phase = .finished(count == 1 ? "Updated 1 issue in Linear" : "Updated \(count) issues in Linear")
            try? await Task.sleep(for: .seconds(1.5))
            if case .finished = phase { close() }
        } catch {
            if phase == .applying { fail(error.localizedDescription) }
            linear.refresh()
        }
    }

    func cancel() {
        autoStop?.cancel()
        retag?.cancel()
        preparation?.cancel()
        recorder.cancel()
        close()
    }

    private func fail(_ message: String) {
        recorder.cancel()
        autoStop?.cancel()
        phase = .failed(message)
    }

    private func close() {
        phase = .idle
        preparation = nil
    }

    #if DEBUG
    /// Debug builds only (launch with --voice-demo): plays a scripted note through the island
    /// with sample issues, no microphone or Linear account, to check the design end to end.
    func runDemo() async {
        catalog = VoiceCatalog(
            projects: ["Atlas", "Portfolio", "Lumen"].map { VoiceCatalog.Project(id: $0, name: $0, teamKey: "HOME") },
            labels: [VoiceCatalog.Label(id: "design", name: "Design", teamKey: nil)],
            defaultTeamKey: "HOME"
        )
        func issue(_ title: String, _ project: String?, cycle: Bool = true) -> LinearIssue {
            LinearIssue(id: title, identifier: "HOME-1", title: title, url: URL(string: "https://linear.app/x/issue/HOME-1")!,
                        priority: 2, stateName: "Todo", stateType: "unstarted", stateColor: "#e2e2e2", statePosition: 1,
                        teamKey: "HOME", dueDate: nil, inCurrentCycle: cycle, inUpcomingCycle: !cycle,
                        projectID: project, projectName: project)
        }
        liveIssues = [
            issue("Wireframe the key Atlas pages", "Atlas"),
            issue("Design the Atlas screens in high fidelity", "Atlas"),
            issue("Pick portfolio projects and format", "Portfolio", cycle: false),
            issue("Renew the car insurance", nil, cycle: false),
        ]
        transcript = ""
        live = LiveTagging()
        changes = []
        phase = .listening
        startedAt = Date()
        onPresent?()

        let note = "I need to find the warranty card, make a copy of it, and send it to the repair shop and also have to pick up parcels from two places."
        for word in note.split(separator: " ") {
            try? await Task.sleep(for: .milliseconds(140))
            guard phase == .listening else { return }
            transcript += (transcript.isEmpty ? "" : " ") + word
            levels = Array(levels.dropFirst()) + [Double.random(in: 0.25...0.95)]
            scheduleRetag()
        }
        try? await Task.sleep(for: .seconds(2))
        guard phase == .listening else { return }
        phase = .thinking
        do {
            let planned = try await VoicePlanner().plan(transcript: note, issues: liveIssues, catalog: catalog, onProgress: { [weak self] done, total in
                Task { @MainActor in self?.progress = (done, total) }
            })
            changes = planned
            phase = .review
        } catch {
            fail(error.localizedDescription)
        }
    }
    #endif

    /// Re-tags shortly after the transcript settles, so a burst of partial results tags once.
    private func scheduleRetag() {
        retag?.cancel()
        retag = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            let tagged = LiveTagger.tag(self.transcript, issues: self.liveIssues, catalog: self.catalog)
            Motion.perform(Motion.snappy) { self.live = tagged }
        }
    }

    /// Names the recognizer should expect: projects, labels and the distinctive words in issue
    /// titles ("Atlas", "Lumen"), which general dictation would otherwise mishear.
    private static func vocabulary(catalog: VoiceCatalog, issues: [LinearIssue]) -> [String] {
        let names = catalog.projects.map(\.name) + catalog.labels.map(\.name)
        let titleWords = issues.flatMap { issue in
            issue.title.split { !$0.isLetter && !$0.isNumber }.dropFirst().map(String.init)
                .filter { $0.count >= 3 && $0.first?.isUppercase == true }
        }
        var seen = Set<String>()
        return (names + titleWords).filter { seen.insert($0.lowercased()).inserted }.prefix(200).map { $0 }
    }

    /// Projects and labels from the last note, so live tagging works from the first word.
    private static func cachedCatalog() -> VoiceCatalog? {
        UserDefaults.standard.data(forKey: catalogKey).flatMap { try? JSONDecoder().decode(VoiceCatalog.self, from: $0) }
    }

    private static func cache(_ catalog: VoiceCatalog) {
        UserDefaults.standard.set(try? JSONEncoder().encode(catalog), forKey: catalogKey)
    }
}
