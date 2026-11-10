import Foundation
import FoundationModels
import NaturalLanguage

// The on-device model is small, so it only makes the judgment calls: splitting a note into
// requests and deciding what each one means. Dates, priority, sprint placement, projects and
// labels are read from the speaker's own words, and every model answer is checked against them
// before it's shown.

// MARK: - What the model returns

@Generable
struct NoteBreakdown {
    @Guide(description: "Each separate request about the speaker's tasks, copied word for word from the note. Empty if the note isn't about tasks.")
    var requests: [String]
}

@Generable
enum RequestKind {
    case create
    case subtask
    case update
    case comment
    case none
}

@Generable
struct RequestDecision {
    @Guide(description: "create: a new task unrelated to the candidates. subtask: a new step needed for one of the candidate tasks. update: a change to a candidate task itself. comment: something to remember about a candidate task. none: not a task request.")
    var kind: RequestKind

    @Guide(description: "For subtask, update and comment: the number of the candidate task. Otherwise 0.")
    var candidate: Int

    @Guide(description: "For create and subtask: a short imperative task title without dates, like \"Book dentist appointment\". Otherwise empty.")
    var title: String
}

enum StatusChange {
    case unchanged
    case todo
    case inProgress
    case done
    case canceled
}

enum Placement {
    case unchanged
    case thisWeek
    case nextWeek
    case backlog
}

// MARK: - Workspace catalog

/// The workspace's projects and labels, so new tasks can be filed in the right place.
struct VoiceCatalog: Codable {
    struct Project: Identifiable, Hashable, Codable {
        let id: String
        let name: String
        let teamKey: String
    }

    struct Label: Hashable, Codable {
        let id: String
        let name: String
        /// Nil for workspace-wide labels.
        let teamKey: String?
    }

    var projects: [Project] = []
    var labels: [Label] = []
    /// Team for new tasks that don't belong to a project or parent task.
    var defaultTeamKey: String?
}

// MARK: - What the review panel shows

/// A validated change, ready to review and to send to Linear.
struct ProposedChange: Identifiable {
    let id = UUID()
    /// The issue being changed, or nil for a new issue.
    var existing: LinearIssue?
    /// A new issue's title. Editable in the review panel.
    var title = ""
    var status: StatusChange = .unchanged
    /// yyyy-MM-dd
    var dueDate: String?
    /// 1...4
    var priority: Int?
    var placement: Placement = .unchanged
    var comment: String?

    // New issues only.
    /// The issue description: what the speaker said about this task.
    var summary: String?
    var project: VoiceCatalog.Project?
    var parent: LinearIssue?
    var labels: [VoiceCatalog.Label] = []
    var teamKey: String?
    /// An open issue this new one looks like; such changes start unticked.
    var possibleDuplicate: LinearIssue?
    /// A new parent from this same note ("bundle these under …"), linked once it's created.
    var parentChangeID: UUID?
    /// Which spoken sentence this came from, so "these" and "the following" know what they mean.
    var sentenceIndex = 0

    var isSelected = true

    var isNew: Bool { existing == nil }
    var headline: String { existing?.title ?? title }

    /// Team the new issue is created in: its project's, else its parent's, else the default.
    var resolvedTeamKey: String? { project?.teamKey ?? parent?.teamKey ?? teamKey }

    var details: [String] {
        var parts: [String] = []
        if let parent { parts.append("Sub-task of “\(parent.title)”") }
        switch status {
        case .unchanged: break
        case .todo: parts.append("→ Todo")
        case .inProgress: parts.append("→ In Progress")
        case .done: parts.append("→ Done")
        case .canceled: parts.append("→ Canceled")
        }
        if let dueDate { parts.append("Due \(Self.displayDate(dueDate))") }
        if let priority { parts.append(["", "Urgent", "High priority", "Medium priority", "Low priority"][priority]) }
        switch placement {
        case .unchanged: break
        case .thisWeek: parts.append("This Week")
        case .nextWeek: parts.append("Next Week")
        case .backlog: parts.append("Backlog")
        }
        parts += labels.map { "#\($0.name)" }
        if let comment { parts.append("Comment: “\(comment)”") }
        return parts
    }

    private static func displayDate(_ day: String) -> String {
        guard let date = VoicePlanner.dayFormatter.date(from: day) else { return day }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

// MARK: - Planner

enum VoicePlannerError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        }
    }
}

/// Turns a transcript into proposed Linear changes with Apple's on-device model.
struct VoicePlanner {
    /// Why the on-device model can't be used right now, or nil when it's ready.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to use voice notes."
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence, which voice notes need."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still getting ready. Try again in a few minutes."
        case .unavailable:
            return "Apple Intelligence isn't available right now."
        }
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The on-device model with guardrails meant for transforming the user's own text, so ordinary
    /// notes ("renew my passport") aren't refused. Every call still falls back to rules on refusal.
    static let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    /// How many likely issues the model chooses from for each request.
    private static let candidateCount = 8
    /// Long brain dumps are split into chunks of about this many words, to fit the model's context.
    private static let chunkWords = 120
    private static let maxRequests = 15

    private static let breakdownInstructions = """
    Find each separate request about the speaker's own tasks in a spoken note: new things to do,
    steps for existing work, and updates like finishing or rescheduling something.
    Copy every request out exactly as spoken, word for word. Don't add, summarize or rephrase anything.
    Leave out small talk. If the note isn't about tasks, return no requests.
    """

    private static let decisionInstructions = """
    You decide what one spoken request means for the speaker's task list.
    - create: a new task that isn't one of the candidates and isn't a step of one.
    - subtask: a new step the speaker needs to do as part of one of the candidate tasks.
    - update: a change to a candidate task itself, e.g. finishing it, starting it, rescheduling or reprioritizing it.
    - comment: the speaker wants to remember or note something about one of the candidate tasks.
    - none: the request isn't about a task.
    Match candidates by meaning, not exact wording. If no candidate clearly fits, it's create.
    """

    /// - Parameter cycleEnd: When the current sprint ends; new tasks due after it go to next week.
    /// - Parameter onProgress: Called with (requests decided, total requests) as the plan comes together.
    func plan(transcript: String, issues: [LinearIssue], catalog: VoiceCatalog, cycleEnd: Date? = nil, today: Date = Date(),
              onProgress: ((Int, Int) -> Void)? = nil) async throws -> [ProposedChange] {
        if let reason = Self.unavailableReason { throw VoicePlannerError.unavailable(reason) }

        var requests: [(text: String, recovered: Bool)] = []
        for chunk in Self.chunks(of: transcript) {
            // If the model can't or won't split the note, the note's own sentences stand in.
            let modelRequests = (try? await LanguageModelSession(model: Self.model, instructions: Self.breakdownInstructions)
                .respond(to: "Spoken note: \"\(chunk)\"", generating: NoteBreakdown.self)
                .content.requests) ?? Self.sentences(of: chunk)
            let found = Self.verbatim(modelRequests, in: chunk).flatMap(Self.splitCompound)
            requests += found.map { ($0, false) }
            requests += Self.missedSentences(in: chunk, besides: found).map { ($0, true) }
        }

        // "Bundle these as subtasks under …" is an instruction, not a task. Tasks it lists by name
        // come from the instruction itself, so other requests from that sentence are dropped.
        let sentenceList = Self.sentences(of: transcript)
        let directives = sentenceList.enumerated().compactMap { BundleDirective.parse($0.element, index: $0.offset) }
        let listingSentences = Set(directives.filter { if case .listed = $0.children { true } else { false } }.map(\.sentenceIndex))
        requests = requests
            .flatMap { request in Self.sentences(of: request.text).map { (text: $0, recovered: request.recovered) } }
            .compactMap { request in
                guard !listingSentences.contains(Self.sentenceIndex(of: request.text, in: sentenceList)),
                      let kept = BundleDirective.withoutInstructions(request.text)
                else { return nil }
                return (kept, request.recovered)
            }

        var changes: [ProposedChange] = []
        let total = min(requests.count, Self.maxRequests)
        for (index, request) in requests.prefix(Self.maxRequests).enumerated() {
            onProgress?(index, total)
            if var change = try await decide(request: request.text, recovered: request.recovered, transcript: transcript,
                                             issues: issues, catalog: catalog, cycleEnd: cycleEnd, today: today) {
                change.sentenceIndex = Self.sentenceIndex(of: request.text, in: sentenceList)
                changes.append(change)
            }
        }
        guard !directives.isEmpty else { return changes }
        return try await bundle(changes, by: directives, transcript: transcript, issues: issues, catalog: catalog)
    }

    /// "For the portfolio one" when the speaker said "For the portfolio one, remember to …" and the
    /// request is just "remember to …".
    static func leadIn(before request: String, in transcript: String) -> String? {
        let sentenceList = sentences(of: transcript)
        let sentence = sentenceList[sentenceIndex(of: request, in: sentenceList)]
        guard let range = sentence.range(of: request.trimmingCharacters(in: .punctuationCharacters), options: .caseInsensitive) else { return nil }
        let prefix = sentence[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !prefix.isEmpty, words(prefix).count <= 4,
              contextLeadIns.contains(where: { prefix.lowercased().hasPrefix($0) })
        else { return nil }
        return prefix
    }

    /// The spoken sentence a request came from: the one sharing the most words with it.
    static func sentenceIndex(of request: String, in sentences: [String]) -> Int {
        let requestTokens = Set(tokens(request))
        return sentences.indices.max { a, b in
            requestTokens.intersection(tokens(sentences[a])).count < requestTokens.intersection(tokens(sentences[b])).count
        } ?? 0
    }

    /// Sentences the model skipped that still have content, so a dropped "I finished the
    /// wireframes" isn't lost. Each is decided on its own like any other request.
    private static func missedSentences(in chunk: String, besides requests: [String]) -> [String] {
        let requestTokens = Set(requests.flatMap(tokens))
        return sentences(of: chunk).filter { sentence in
            let sentenceTokens = tokens(sentence)
            let covered = Double(sentenceTokens.filter(requestTokens.contains).count) / Double(max(sentenceTokens.count, 1))
            return covered < 0.5 && !words(sentence).isEmpty
        }
    }

    /// Sentence-aligned chunks of the transcript, each small enough for the on-device model.
    private static func chunks(of transcript: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for sentence in sentences(of: transcript) {
            if !current.isEmpty, (current + " " + sentence).split(separator: " ").count > chunkWords {
                chunks.append(current)
                current = sentence
            } else {
                current = current.isEmpty ? sentence : current + " " + sentence
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    static func sentences(of text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                sentences.append(sentence)
            }
        }
        return sentences.isEmpty ? [text] : sentences
    }

    /// Keeps the requests the model copied from the note. If it rephrased them all, splits the note
    /// into sentences instead, so later checks always read the speaker's own words.
    private static func verbatim(_ requests: [String], in transcript: String) -> [String] {
        let spoken = Set(tokens(transcript))
        let copied = requests.filter { request in
            let words = tokens(request)
            return !words.isEmpty && Double(words.filter(spoken.contains).count) / Double(words.count) >= 0.8
        }
        if !copied.isEmpty || requests.isEmpty { return copied }
        return sentences(of: transcript)
    }

    /// "export the Figma files and write a handoff doc" is two tasks; "research and design the
    /// page" or "buy milk and eggs" is one. Splits on "and" only when both sides name real work.
    static func splitCompound(_ request: String) -> [String] {
        // A spoken list ("renew my passport, get visa photos, fill out the form") splits at commas
        // where the next part starts with an action; "For Atlas, I need to …" stays together.
        var listed: [String] = []
        for part in request.components(separatedBy: ", ") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            let item = trimmed.hasPrefix("and ") ? String(trimmed.dropFirst(4)) : trimmed
            let afterLeadIn = listed.last.map { last in
                contextLeadIns.contains { last.lowercased().hasPrefix($0) } && words(last).count <= 3
            } ?? false
            if listed.isEmpty || afterLeadIn || !VoicePlanner.startsWithVerb(item) || words(item).count < 2 {
                listed.append(listed.isEmpty ? trimmed : (listed.removeLast() + ", " + trimmed))
            } else {
                listed.append(item)
            }
        }
        return listed.flatMap(splitOnAnd)
    }

    private static func splitOnAnd(_ request: String) -> [String] {
        var pieces: [String] = []
        for piece in request.components(separatedBy: " and ") {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            if let last = pieces.last, words(last).count < 2 || words(trimmed).count < 2 {
                pieces[pieces.count - 1] = last + " and " + trimmed
            } else {
                pieces.append(trimmed)
            }
        }
        return pieces.filter { !$0.isEmpty }
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// - Parameter recovered: A sentence the model skipped; it only becomes a new task if it asks for one itself.
    func decide(request: String, recovered: Bool, transcript: String, issues: [LinearIssue], catalog: VoiceCatalog, cycleEnd: Date?, today: Date) async throws -> ProposedChange? {
        // Rank issues by shared words; on a tie, the one whose topic was said first
        // ("For the portfolio one, … Lumen …" is about the portfolio). A short lead-in said just
        // before the request counts too, in case the model trimmed it off.
        let spokenRequest = Self.leadIn(before: request, in: transcript).map { $0 + " " + request } ?? request
        let requestWords = Self.words(spokenRequest)
        let spokenOrder = spokenRequest.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        func firstMention(of shared: Set<String>) -> Int {
            spokenOrder.firstIndex { shared.contains(Self.words($0).first ?? "") } ?? spokenOrder.count
        }
        let ranked = issues.enumerated()
            .map { entry -> (issue: LinearIssue, score: Int, position: Int, index: Int) in
                let shared = requestWords.intersection(Self.words(entry.element.title))
                return (entry.element, shared.count, firstMention(of: shared), entry.offset)
            }
            .sorted { ($1.score, $0.position, $0.index) < ($0.score, $1.position, $1.index) }
        let candidates = Array(ranked.prefix(Self.candidateCount))

        let prompt = """
        Request: "\(request)"

        Candidate tasks:
        \(candidates.isEmpty ? "(none)" : candidates.enumerated().map { "\($0.offset + 1). \($0.element.issue.title)" }.joined(separator: "\n"))
        """
        // If the model can't decide, the word rules below still sort it out from a "create" guess.
        let decision = (try? await LanguageModelSession(model: Self.model, instructions: Self.decisionInstructions)
            .respond(to: prompt, generating: RequestDecision.self)
            .content) ?? RequestDecision(kind: .create, candidate: 0, title: "")

        // What the speaker actually said decides dates, priority and placement.
        let said = Said(request: request, transcript: transcript)
        let dueDate = Self.dueDate(in: said.context, today: today)

        // Which existing issue this is about, if any. The model's pick must share words with the
        // request and can't be beaten by a closer match; a clear word match wins if it picked nothing.
        let picked = candidates.indices.contains(decision.candidate - 1) ? candidates[decision.candidate - 1] : nil
        var related: LinearIssue? = {
            guard decision.kind != .create, let best = candidates.first, best.score > 0 else { return nil }
            if let picked, picked.score > 0 { return (picked.score >= best.score ? picked : best).issue }
            return best.score >= 2 ? best.issue : nil
        }()

        // An "update" that changes nothing but asks for something to be done is really a new step.
        var kind = decision.kind
        if kind == .update, let related, said.asksForNewTaskHere,
           said.status(for: related.title) == .unchanged, said.priority == nil, said.placement == .unchanged, dueDate == nil, !said.wantsNote {
            kind = .subtask
        }

        // And a "new task" that only describes a change ("I'm starting on…", "move … to the backlog")
        // without asking for anything new is really an update to the closest existing issue.
        // The model sometimes calls such a change "not a task" too.
        let best = candidates.first.flatMap { $0.score > 0 ? $0.issue : nil }
        let describesChange = said.status(for: candidates.first?.issue.title) != .unchanged || said.placement != .unchanged
        // A note about existing work goes on the closest issue if the model didn't pick one.
        if related == nil, kind == .comment || (said.wantsNote && kind != .create), let best {
            kind = .comment
            related = best
        }
        let resolvedByModel = related != nil && (kind == .update || kind == .comment)
        if !resolvedByModel, describesChange, !said.asksForNewTaskHere, let best {
            kind = .update
            related = best
        }
        guard kind != .none else { return nil }

        if let related, kind == .update || kind == .comment {
            var change = ProposedChange(existing: related, status: said.status(for: related.title), dueDate: dueDate, priority: said.priority, placement: said.placement)
            if said.wantsNote {
                change.comment = request.prefix(1).uppercased() + request.dropFirst()
            }
            return change.details.isEmpty ? nil : change
        }

        // "I finished X" is news about existing work, never a new task.
        if said.status(for: candidates.first?.issue.title) == .done {
            guard let best = candidates.first, best.score > 0 else { return nil }
            return ProposedChange(existing: best.issue, status: .done)
        }

        // Otherwise it's a new task, as a sub-task when it's a step of an existing one.
        guard recovered ? said.asksForNewTaskHere : said.asksForNewTask else { return nil }
        let parent = kind == .subtask ? related : nil
        let title = Self.title(modelTitle: decision.title, request: request, transcript: transcript)
        guard !title.isEmpty else { return nil }

        var change = ProposedChange(title: title)
        let status = said.status(for: nil)
        change.status = status == .todo ? .unchanged : status
        change.dueDate = dueDate
        change.priority = said.priority
        // A new task that covers part of an existing one ("write the docs" for "build the tool and docs")
        // is a step of it rather than a duplicate.
        change.parent = parent ?? Self.containing(title, among: issues)
        change.summary = Self.summary(for: request, in: transcript)
        change.project = change.parent?.projectID.flatMap { id in catalog.projects.first { $0.id == id } }
            ?? Self.project(mentionedIn: said.scope, catalog: catalog)
        change.teamKey = catalog.defaultTeamKey
        let team = change.resolvedTeamKey
        change.labels = Self.labels(mentionedIn: said.context, catalog: catalog, teamKey: team)
        change.possibleDuplicate = Self.duplicate(of: title, among: issues)
        change.isSelected = change.possibleDuplicate == nil

        // New tasks land in the current sprint unless the speaker said otherwise, they're due after
        // it, or they're a step of work planned for later.
        let dueAfterSprint = dueDate.flatMap(Self.dayFormatter.date(from:)).map { due in cycleEnd.map { due >= $0 } ?? false } ?? false
        if said.placement != .unchanged {
            change.placement = said.placement
        } else if dueAfterSprint || change.parent?.inUpcomingCycle == true {
            change.placement = .nextWeek
        } else if let parent = change.parent, !parent.inCurrentCycle {
            change.placement = .backlog
        } else {
            change.placement = .thisWeek
        }
        return change
    }

    // MARK: - Filing new tasks

    /// The model's title when it sticks to the speaker's words, otherwise one cut from the request.
    private static func title(modelTitle: String, request: String, transcript: String) -> String {
        let spoken = Set(words(transcript))
        let modelWords = words(modelTitle)
        let faithful = !modelWords.isEmpty && Double(modelWords.filter(spoken.contains).count) / Double(modelWords.count) >= 0.75
        return cleanTitle(faithful ? modelTitle : request)
    }

    /// The issue description: the sentence the task came from, in the speaker's words.
    private static func summary(for request: String, in transcript: String) -> String {
        let requestWords = Set(tokens(request))
        let source = sentences(of: transcript).max { a, b in
            requestWords.intersection(tokens(a)).count < requestWords.intersection(tokens(b)).count
        } ?? request
        return "> \(source)\n\n_From a voice note._"
    }

    /// The project named closest before (or within) the request, so "for Atlas, X, and for the
    /// portfolio, Y" files Y under Portfolio. Longer names win ties.
    static func project(mentionedIn scope: String, catalog: VoiceCatalog) -> VoiceCatalog.Project? {
        let said = words(scope)
        var best: (project: VoiceCatalog.Project, position: Int, length: Int)?
        for project in catalog.projects {
            let name = words(project.name)
            guard !name.isEmpty, name.isSubset(of: said) else { continue }
            let position = scope.range(of: project.name.lowercased(), options: .backwards)
                .map { scope.distance(from: scope.startIndex, to: $0.lowerBound) } ?? 0
            if best == nil || position > best!.position || (position == best!.position && name.count > best!.length) {
                best = (project, position, name.count)
            }
        }
        return best?.project
    }

    /// Labels whose name was said, from the task's team or the whole workspace.
    static func labels(mentionedIn context: String, catalog: VoiceCatalog, teamKey: String?) -> [VoiceCatalog.Label] {
        let said = words(context)
        var seen = Set<String>()
        return catalog.labels.filter { label in
            let name = words(label.name)
            guard !name.isEmpty, name.isSubset(of: said), label.teamKey == nil || label.teamKey == teamKey else { return false }
            return seen.insert(label.name.lowercased()).inserted
        }
    }

    /// An open issue with essentially the same title (most words shared both ways).
    static func duplicate(of title: String, among issues: [LinearIssue]) -> LinearIssue? {
        let newWords = words(title)
        guard !newWords.isEmpty else { return nil }
        var best: (issue: LinearIssue, similarity: Double)?
        for issue in issues {
            let existingWords = words(issue.title)
            let similarity = Double(newWords.intersection(existingWords).count) / Double(newWords.union(existingWords).count)
            if similarity >= 0.75, similarity > (best?.similarity ?? 0) {
                best = (issue, similarity)
            }
        }
        return best?.issue
    }

    /// A bigger open issue that the new task is part of: its title contains nearly all of the
    /// new task's words, plus more.
    static func containing(_ title: String, among issues: [LinearIssue]) -> LinearIssue? {
        let newWords = words(title)
        guard newWords.count >= 2, duplicate(of: title, among: issues) == nil else { return nil }
        var best: (issue: LinearIssue, shared: Int)?
        for issue in issues {
            let shared = newWords.intersection(words(issue.title)).count
            if shared >= 2, Double(shared) / Double(newWords.count) >= 0.75, shared > (best?.shared ?? 0) {
                best = (issue, shared)
            }
        }
        return best?.issue
    }

    // MARK: - Reading the speaker's words

    /// Reads status, priority, placement and intent from what the speaker actually said: the
    /// request plus the spoken clause it came from (so "…, high priority" isn't lost if the
    /// model trimmed it), never from the model's own wording.
    struct Said {
        /// The request plus the spoken segments it came from and any qualifier segments right after
        /// them ("…, it's urgent", "…, by Friday"), lowercased. Other tasks in the same sentence stay out.
        let context: String
        /// The spoken sentence up to the end of this request, for things that scope what follows
        /// them, like "For the Atlas handoff, …". Later parts of the sentence don't apply.
        let scope: String
        let transcript: String

        init(request: String, transcript: String) {
            let requestTokens = Set(VoicePlanner.tokens(request))
            let sentences = VoicePlanner.sentences(of: transcript)
            let source = sentences.max { a, b in
                requestTokens.intersection(VoicePlanner.tokens(a)).count < requestTokens.intersection(VoicePlanner.tokens(b)).count
            } ?? request

            // Segments: the sentence split at commas, colons, semicolons and "and".
            let segments = source
                .components(separatedBy: CharacterSet(charactersIn: ",;:"))
                .flatMap { $0.components(separatedBy: " and ") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var picked: [String] = []
            var extending = false
            var lastCovered: Int?
            for (index, segment) in segments.enumerated() {
                let tokens = VoicePlanner.tokens(segment)
                let shared = Double(tokens.filter(requestTokens.contains).count)
                // Mostly the request's words, or the whole request said inside a longer segment.
                let covered = !tokens.isEmpty && (shared / Double(tokens.count) >= 0.5 || shared / Double(max(requestTokens.count, 1)) >= 0.8)
                if covered {
                    picked.append(segment)
                    extending = true
                    lastCovered = index
                } else if extending, VoicePlanner.words(segment).isEmpty {
                    picked.append(segment)  // a qualifier like "it's urgent" or "by Friday"
                } else {
                    extending = false
                }
            }
            context = ([request] + picked).joined(separator: " ").lowercased()
            scope = (lastCovered.map { segments[...$0].joined(separator: ", ") } ?? request).lowercased()
            self.transcript = transcript.lowercased()
        }

        private func mentions(_ phrases: [String], in text: String) -> Bool {
            phrases.contains { phrase in
                text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b", options: .regularExpression) != nil
            }
        }

        /// Status the speaker stated. Past tense of the issue's leading verb also counts as done
        /// ("confirmed" for "Confirm Atlas scope", "booked" for "Book a checkup").
        func status(for issueTitle: String?) -> StatusChange {
            if mentions(Self.canceledPhrases, in: context) { return .canceled }
            if mentions(Self.reopenedPhrases, in: context) { return .todo }
            let negated = mentions(["not", "haven't", "hasn't", "didn't", "isn't", "yet", "still"], in: context)
            var doneWords = Self.donePhrases
            if let verb = issueTitle?.lowercased().split(separator: " ").first.map(String.init), verb.count >= 3 {
                doneWords += [verb + "ed", verb + "d"]
            }
            // "I need to get my bike service done" asks for work rather than reporting it; then only
            // an explicit "mark … done" counts.
            let intends = mentions(Self.intentPhrases, in: context) && !mentions(["mark", "marked", "set", "move", "moved"], in: context)
            if !negated, !intends, mentions(doneWords, in: context) { return .done }
            if !intends, mentions(Self.startedPhrases, in: context) { return .inProgress }
            return .unchanged
        }

        static let intentPhrases = [
            "need to", "needs to", "have to", "has to", "got to", "gotta", "want to", "going to", "should", "must",
            "remind me to", "remember to", "don't forget to", "make sure to", "i'll", "i will", "let's",
        ]

        // The spoken cues behind each rule, shared with the live tagger's highlighting.
        static let canceledPhrases = ["cancel", "canceled", "cancelled", "drop", "dropped", "scrap", "scrapped", "not doing", "won't do", "no longer"]
        static let reopenedPhrases = ["reopen", "reopened", "back to todo", "not done"]
        static let donePhrases = ["done", "finished", "completed", "wrapped up", "shipped", "closed", "knocked out", "sorted out", "booked", "confirmed"]
        static let startedPhrases = ["start", "started", "starting", "working on", "began", "begin", "picking up", "picked up", "in progress", "on it"]
        static let lowPriorityPhrases = ["not urgent", "not important", "low priority"]
        static let urgentPhrases = ["urgent", "asap", "right away", "top priority", "critical"]
        static let highPriorityPhrases = ["high priority", "important"]
        static let mediumPriorityPhrases = ["medium priority", "normal priority"]
        static let backlogPhrases = ["not this week", "backlog", "someday", "eventually", "no rush"]
        static let nextWeekPhrases = ["next week", "next sprint", "next cycle"]
        static let thisWeekPhrases = ["this week", "this sprint", "current sprint", "this cycle"]

        static let newTaskPhrases = [
            "add", "create", "new task", "new issue", "remind me", "need to", "needs to", "have to", "has to", "should", "must",
            "todo", "to-do", "to do", "gotta", "got to", "don't forget", "schedule", "book", "plan", "task", "make sure",
            "follow up", "i'll", "i will", "i want to", "let's", "next step", "remember to",
        ]

        /// The note as a whole asks for something to be done.
        var asksForNewTask: Bool { mentions(Self.newTaskPhrases, in: transcript) }

        /// This request, or the sentence leading up to it ("I should pick X and get Y"), asks for something to be done.
        var asksForNewTaskHere: Bool { mentions(Self.newTaskPhrases, in: context + " " + scope) }

        var priority: Int? {
            if mentions(Self.lowPriorityPhrases, in: context) { return 4 }
            if mentions(Self.urgentPhrases, in: context) { return 1 }
            if mentions(Self.highPriorityPhrases, in: context) { return 2 }
            if mentions(Self.mediumPriorityPhrases, in: context) { return 3 }
            return nil
        }

        var wantsNote: Bool {
            mentions(["remember", "note", "comment", "keep in mind", "mention", "don't forget"], in: context)
        }

        var placement: Placement {
            if mentions(Self.backlogPhrases, in: context) { return .backlog }
            if mentions(Self.nextWeekPhrases, in: context) { return .nextWeek }
            if mentions(Self.thisWeekPhrases, in: context) { return .thisWeek }
            return .unchanged
        }
    }

    /// Uses macOS's own date detection ("Friday", "tomorrow", "Oct 5") rather than the model's arithmetic.
    static func dueDate(in text: String, today: Date) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let nsText = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let phrase = nsText.substring(with: match.range).lowercased()
            // "this week" / "next week" are sprint placement, not due dates.
            guard !phrase.contains("week"), !phrase.contains("now"), var date = match.date else { continue }
            // "before Sunday" comes back as a range starting now; the deadline is its end.
            if match.duration > 0 { date = date.addingTimeInterval(match.duration) }
            let startOfToday = Calendar.current.startOfDay(for: today)
            // "before Sunday" can come back as last Sunday; a weekday always means the coming one.
            while date < startOfToday, weekdayNames.contains(where: phrase.contains) {
                date = Calendar.current.date(byAdding: .day, value: 7, to: date) ?? startOfToday
            }
            return dayFormatter.string(from: max(date, startOfToday))
        }
        return nil
    }

    static let weekdayNames = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    private static let titleLeadIns = [
        "oh and ", "and ", "also ", "then ", "so ", "please ", "can you ", "remind me to ", "i need to ", "i have to ",
        "i should ", "i must ", "i gotta ", "i've got to ", "i'll ", "i will ", "i want to ", "let's ", "gotta ",
        "need to ", "we need to ", "add a task to ", "add a task for ", "create a task to ", "don't forget to ",
        "make sure to ", "add ", "create ", "new task ",
    ]

    /// "I need to", "we should", "remind me to"…: what comes after is the task itself.
    private static let intentPattern = "\\b(?:(?:i|we)(?:'ll| will| would)? )?(?:really )?(?:need(?:s)? to|have to|has to|got to|gotta|want to|going to|should|must|remember to|don't forget to|make sure to|remind me to)\\b"

    /// Context phrases that introduce a task rather than name it ("For the Atlas handoff, …").
    static let contextLeadIns = ["for the ", "for my ", "for ", "about the ", "regarding ", "as for ", "on the ", "with the ", "oh", "okay", "ok", "um", "so"]
    private static let trailingQualifiers = ["urgent", "asap", "high priority", "low priority", "not urgent", "it's urgent", "this week", "next week"]

    /// Turns a request (or the model's title) into a task title: the comma-separated part that names
    /// the task, without lead-ins like "remind me to", qualifiers like "high priority", or dates.
    static func cleanTitle(_ raw: String) -> String {
        // Start after the intent ("Okay so for the Atlas handoff I need to | export the files").
        var raw = raw
        if let intent = raw.range(of: intentPattern, options: [.regularExpression, .caseInsensitive]),
           !raw[intent.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty {
            raw = String(raw[intent.upperBound...])
        }
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
        var title = parts.first { part in
            let lower = part.lowercased()
            return !part.isEmpty
                && !contextLeadIns.contains(where: { lower.hasPrefix($0) && !lower.contains(" need") && !lower.contains(" have to") })
                && !trailingQualifiers.contains(lower)
        } ?? parts.first ?? ""

        var trimmed = true
        while trimmed {
            trimmed = false
            for leadIn in titleLeadIns where title.lowercased().hasPrefix(leadIn) {
                title = String(title.dropFirst(leadIn.count))
                trimmed = true
            }
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.firstMatch(in: title, range: NSRange(location: 0, length: (title as NSString).length)),
           let range = Range(match.range, in: title) {
            title.removeSubrange(range)
        }
        trimmed = true
        while trimmed {
            trimmed = false
            title = title.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            for suffix in [" this week", " next week", " on", " by", " for", " before", " due", " at"] where title.lowercased().hasSuffix(suffix) {
                title = String(title.dropLast(suffix.count))
                trimmed = true
            }
        }
        title = imperative(title.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)))
        return title.prefix(1).uppercased() + title.dropFirst()
    }

    /// "Booking flights" → "Book flights", "writing the doc" → "write the doc", using Apple's
    /// on-device lemmatizer for the first word.
    static func imperative(_ title: String) -> String {
        guard let firstSpace = title.firstIndex(of: " ") ?? Optional(title.endIndex) else { return title }
        let first = String(title[..<firstSpace])
        guard first.count > 4, first.lowercased().hasSuffix("ing") else { return title }
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = title
        let (lemma, _) = tagger.tag(at: title.startIndex, unit: .word, scheme: .lemma)
        guard let base = lemma?.rawValue, !base.isEmpty, base.lowercased() != first.lowercased() else { return title }
        return base + title[firstSpace...]
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "this", "that", "now", "also", "just", "add", "task", "need", "want", "should",
        "week", "next", "today", "tomorrow", "urgent", "done", "finish", "start", "work", "mark", "move", "push", "put",
        "set", "make", "sure", "have", "has", "been", "from", "into", "about", "one", "thing", "some", "all", "get",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "priority", "important", "sprint",
        "high", "low", "medium", "backlog", "stuff", "later", "someday", "remind", "remember", "please", "include",
        "then", "first", "going", "gonna", "really", "like", "will", "can", "could", "would", "there", "their", "they",
    ]

    /// Lowercased content words with simple suffixes removed, for comparing speech to titles and names.
    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map { word -> String in
                var word = String(word)
                for suffix in ["ing", "ed", "s"] where word.count > suffix.count + 3 && word.hasSuffix(suffix) {
                    word.removeLast(suffix.count)
                    break
                }
                return word
            }
            .filter { $0.count >= 3 && !stopWords.contains($0) })
    }
}
