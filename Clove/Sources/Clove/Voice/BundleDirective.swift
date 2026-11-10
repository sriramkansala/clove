import Foundation

/// A spoken instruction to group tasks rather than a task itself: "bundle these as subtasks under
/// the Goa trip", "put exporting the Figma files and the handoff doc under the Atlas handoff",
/// "group them into one task called trip prep", "make these subtasks of the portfolio task: …".
struct BundleDirective: Equatable {
    /// Which tasks are being grouped.
    enum Children: Equatable {
        /// "these", "them", "all of these", "the above": tasks said before the instruction.
        case before
        /// "the following", "the next ones": tasks said after it.
        case after
        /// "the last three".
        case last(Int)
        /// Named in the instruction itself.
        case listed([String])
    }

    let sentenceIndex: Int
    let children: Children
    /// The parent as said ("the Goa trip", "trip prep"), or nil to name it from its children.
    let parentName: String?
    /// The speaker called the parent a task or issue ("the portfolio task"), so it's an existing
    /// issue rather than a project.
    var parentIsIssue = false

    /// Parses one sentence, or returns nil when it isn't a grouping instruction.
    static func parse(_ sentence: String, index: Int) -> BundleDirective? {
        let text = normalized(sentence)
        guard isInstructionNormalized(text) else { return nil }
        let (listText, colonList) = splitColon(text)
        let name = parentName(in: listText, original: sentence)
        return BundleDirective(
            sentenceIndex: index,
            children: children(in: listText, colonList: colonList, original: sentence),
            parentName: name,
            parentIsIssue: name != nil && matches(listText, "\\b(?:task|issue|ticket|one)\\s*$")
        )
    }

    /// The request with any grouping instruction cut out ("record a demo video, put these under
    /// Atlas" → "record a demo video"), or nil when nothing but the instruction is left.
    static func withoutInstructions(_ text: String) -> String? {
        guard isInstruction(text) else { return text }
        let kept = text.components(separatedBy: CharacterSet(charactersIn: ",;"))
            .flatMap { $0.components(separatedBy: " and ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isInstruction($0) && !VoicePlanner.words($0).isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: ", ")
    }

    /// True for text that's an instruction to group, like a request the model extracted.
    static func isInstruction(_ text: String) -> Bool {
        isInstructionNormalized(normalized(text))
    }

    // MARK: - Parsing

    private static let verbs = "bundle|group|combine|nest|put|make|move|add|turn|club|organi[sz]e"
    private static let connectors = "under|into|as subtasks?|as part of|subtasks? (?:of|under|for)|inside"
    private static let pronouns = "these|them|those|the above|all of these|all these|all of them|all of those|everything|this stuff|these things|these tasks|those tasks|all"

    private static func isInstructionNormalized(_ text: String) -> Bool {
        matches(text, "\\b(?:\(verbs))\\b.*\\b(?:\(connectors))\\b")
            || matches(text, "\\bas subtasks?\\b")
            || matches(text, "\\b(?:main|parent|umbrella) task\\b")
            || matches(text, "^(?:\(pronouns)) (?:are|should be|can be|go|belong) (?:subtasks?|under)\\b")
    }

    /// Lowercased, with "sub tasks" / "sub-tasks" spelled "subtasks" and edge punctuation trimmed.
    private static func normalized(_ sentence: String) -> String {
        var text = sentence.lowercased()
        for (spoken, written) in [("sub-tasks", "subtasks"), ("sub tasks", "subtasks"), ("sub-task", "subtask"), ("sub task", "subtask")] {
            text = text.replacingOccurrences(of: spoken, with: written)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
    }

    /// "make these subtasks of X: a, b" → ("make these subtasks of X", ["a", "b"]).
    private static func splitColon(_ text: String) -> (String, [String]) {
        guard let colon = text.firstIndex(of: ":") else { return (text, []) }
        let items = listItems(String(text[text.index(after: colon)...]))
        return (String(text[..<colon]), items)
    }

    private static func children(in text: String, colonList: [String], original: String) -> Children {
        // Items keep the speaker's capitalization ("Figma"), found case-insensitively in the original.
        func cased(_ items: [String]) -> [String] {
            items.map { item in original.range(of: item, options: .caseInsensitive).map { String(original[$0]) } ?? item }
        }
        if !colonList.isEmpty { return .listed(cased(colonList)) }
        if let count = firstCapture(text, "\\blast (\\w+)\\b").flatMap(number) { return .last(count) }
        if matches(text, "\\b(?:the following|the next (?:ones|few|tasks)|these next|below)\\b") { return .after }
        // "put A and B under X": the items between the verb and the connector.
        if let between = firstCapture(text, "\\b(?:\(verbs))\\s+(.+?)\\s+(?:\(connectors))\\b") {
            let items = listItems(between)
            let onlyPronoun = items.count == 1 && matches(items[0], "^(?:\(pronouns))(?: (?:tasks?|ones|items|things))?$")
            if !items.isEmpty, !onlyPronoun { return .listed(cased(items)) }
        }
        return .before
    }

    private static let parentLeadIns = [
        "a ", "an ", "the ", "one ", "single ", "new ", "main ", "parent ", "big ", "umbrella ", "my ", "our ",
        "task ", "issue ", "ticket ", "called ", "named ", "titled ", "for ", "of ", "that's ", "which is ",
    ]

    private static func parentName(in text: String, original: String) -> String? {
        var raw: String?
        if let named = firstCapture(text, "(?:make|let|set)\\s+(.+?)\\s+(?:be\\s+)?the (?:main|parent|umbrella) task") {
            raw = named
        } else if let named = firstCapture(text, "^(.+?)\\s+(?:is|should be|will be|can be)\\s+the (?:main|parent|umbrella) task") {
            raw = named
        } else if let named = firstCapture(text, "\\b(?:under|into|subtasks? (?:of|under|for)|as part of|inside)\\s+(.+)$") {
            raw = named
        }
        guard var name = raw else { return nil }

        // Strip "a main task called …", "the …", trailing "task" and leftover "as subtasks".
        name = name.replacingOccurrences(of: "\\s+as subtasks?$", with: "", options: .regularExpression)
        var trimmed = true
        while trimmed {
            trimmed = false
            for leadIn in parentLeadIns where name.hasPrefix(leadIn) {
                name.removeFirst(leadIn.count)
                trimmed = true
            }
        }
        name = name.replacingOccurrences(of: "\\s+(?:task|issue|ticket|one)$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !name.isEmpty, !VoicePlanner.words(name).isEmpty,
              !matches(name, "^(?:\(pronouns)|one|it|task|main task|parent task)$") else { return nil }

        // Keep the speaker's capitalization ("Goa trip"), found case-insensitively in the original.
        if let range = original.range(of: name, options: .caseInsensitive) {
            return String(original[range])
        }
        return name
    }

    private static func listItems(_ text: String) -> [String] {
        text.replacingOccurrences(of: ", and ", with: ", ")
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .flatMap { $0.components(separatedBy: " and ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            .filter { !$0.isEmpty }
    }

    private static func number(_ word: String) -> Int? {
        if let value = Int(word) { return value }
        return ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "couple": 2, "few": 3][word]
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func firstCapture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}

// MARK: - Applying groupings to a plan

import FoundationModels
import NaturalLanguage

@Generable
struct UmbrellaTitle {
    @Guide(description: "A short task title, 2 to 5 words, covering all the listed tasks, like \"Plan Goa trip\". If one listed task already covers the others, its exact title.")
    var title: String
}

extension VoicePlanner {
    /// Applies "bundle these under …" instructions: picks or creates each parent and links the
    /// grouped tasks to it as sub-tasks. Parents come first, each followed by its sub-tasks.
    func bundle(_ changes: [ProposedChange], by directives: [BundleDirective], transcript: String,
                issues: [LinearIssue], catalog: VoiceCatalog) async throws -> [ProposedChange] {
        var changes = changes
        let sentences = Self.sentences(of: transcript)
        var previousIndex = -1

        for (position, directive) in directives.enumerated() {
            let nextIndex = position + 1 < directives.count ? directives[position + 1].sentenceIndex : Int.max
            func isLoose(_ change: ProposedChange) -> Bool { change.isNew && change.parentChangeID == nil }

            // Which tasks are grouped.
            var childIDs: [UUID]
            switch directive.children {
            case .before:
                let sentencesInScope = Self.sentencesReferredBack(
                    from: directive, after: previousIndex,
                    tasks: changes.map { (sentence: $0.sentenceIndex, isNew: $0.isNew, title: $0.title, project: $0.project?.name ?? $0.existing?.projectName) }
                )
                childIDs = changes.filter { isLoose($0) && sentencesInScope.contains($0.sentenceIndex) }.map(\.id)
                if childIDs.isEmpty {  // "bundle these" said first, then the tasks
                    childIDs = changes.filter { isLoose($0) && $0.sentenceIndex > directive.sentenceIndex && $0.sentenceIndex < nextIndex }.map(\.id)
                }
            case .after:
                childIDs = changes.filter { isLoose($0) && $0.sentenceIndex > directive.sentenceIndex && $0.sentenceIndex < nextIndex }.map(\.id)
            case .last(let count):
                childIDs = Array(changes.filter { isLoose($0) && $0.sentenceIndex <= directive.sentenceIndex }.suffix(count)).map(\.id)
            case .listed(let items):
                childIDs = []
                for item in items {
                    // Drop a copy the note's own breakdown may already have made of this item.
                    changes.removeAll { $0.isNew && Self.covers(item, $0.title) && Self.covers($0.title, item) }
                    var child: ProposedChange
                    // "pick three projects" is new work; "the wireframes" points at an existing issue.
                    if !Self.startsWithVerb(item), let existing = Self.bestIssue(for: item, among: issues) {
                        child = ProposedChange(existing: existing)  // moved under the parent
                    } else {
                        child = ProposedChange(title: Self.cleanTitle(item))
                        child.placement = .thisWeek
                        child.teamKey = catalog.defaultTeamKey
                        child.summary = "> \(sentences.indices.contains(directive.sentenceIndex) ? sentences[directive.sentenceIndex] : item)\n\n_From a voice note._"
                    }
                    child.sentenceIndex = directive.sentenceIndex
                    changes.append(child)
                    childIDs.append(child.id)
                }
            }
            previousIndex = directive.sentenceIndex
            guard !childIDs.isEmpty else { continue }

            // The parent: one of the grouped tasks, another new task, an existing issue, or a new one.
            var parentChangeID: UUID?
            var parentIssue: LinearIssue?
            var newParentTitle: String?
            if let name = directive.parentName, !directive.parentIsIssue,
               let project = catalog.projects.first(where: { Self.covers(name, $0.name) && Self.covers($0.name, name) }),
               Self.bestIssue(for: name, among: issues) == nil {
                // "Put these under Atlas", where Atlas is a project: file them there, no parent task.
                for index in changes.indices where childIDs.contains(changes[index].id) && changes[index].isNew {
                    changes[index].project = project
                    changes[index].isSelected = true
                }
                continue
            } else if let name = directive.parentName {
                let namedIssue = directive.parentIsIssue ? Self.onlyIssue(covering: name, among: issues) : nil
                if let namedIssue {
                    parentIssue = namedIssue
                    childIDs.removeAll { id in changes.first { $0.id == id }?.existing?.id == namedIssue.id }
                } else if let match = changes.first(where: { childIDs.contains($0.id) && $0.isNew && Self.covers(name, $0.title) }) {
                    parentChangeID = match.id
                    childIDs.removeAll { $0 == match.id }
                } else if let match = changes.first(where: { $0.isNew && $0.parentChangeID == nil && Self.covers(name, $0.title) }) {
                    parentChangeID = match.id
                } else if let existing = Self.bestIssue(for: name, among: issues) {
                    parentIssue = existing
                } else {
                    newParentTitle = Self.cleanTitle(name)
                }
            } else {
                let titles = childIDs.compactMap { id in changes.first { $0.id == id }?.headline }
                let umbrella = try await umbrellaTitle(for: titles)
                if let match = changes.first(where: { childIDs.contains($0.id) && $0.isNew && Self.words($0.title) == Self.words(umbrella) }) {
                    parentChangeID = match.id
                    childIDs.removeAll { $0 == match.id }
                } else {
                    newParentTitle = umbrella
                }
            }
            guard !childIDs.isEmpty else { continue }

            let children = changes.filter { childIDs.contains($0.id) }
            if let title = newParentTitle, !title.isEmpty {
                var parent = ProposedChange(title: title)
                parent.sentenceIndex = directive.sentenceIndex
                parent.teamKey = catalog.defaultTeamKey
                let sentence = sentences.indices.contains(directive.sentenceIndex) ? sentences[directive.sentenceIndex] : ""
                parent.summary = "> \(sentence)\n\n_From a voice note._"
                // Shared project and sprint of its sub-tasks, if they agree.
                let projects = Set(children.compactMap { $0.project ?? $0.existing.flatMap { issue in
                    issue.projectID.flatMap { id in catalog.projects.first { $0.id == id } } } })
                parent.project = projects.count == 1 ? projects.first : Self.project(mentionedIn: sentence.lowercased(), catalog: catalog)
                let placements = Set(children.map { "\($0.placement)" })
                parent.placement = placements.count == 1 ? children[0].placement : .thisWeek
                if parent.placement == .unchanged { parent.placement = .thisWeek }
                let firstChild = changes.firstIndex { childIDs.contains($0.id) } ?? changes.endIndex
                changes.insert(parent, at: firstChild)
                parentChangeID = parent.id
            }

            let parentProject = parentChangeID.flatMap { id in changes.first { $0.id == id }?.project }
            for index in changes.indices where childIDs.contains(changes[index].id) {
                changes[index].parentChangeID = parentChangeID
                changes[index].parent = parentChangeID == nil ? parentIssue : nil
                if changes[index].isNew, changes[index].project == nil {
                    changes[index].project = parentProject ?? parentIssue?.projectID.flatMap { id in catalog.projects.first { $0.id == id } }
                }
                // Grouping something on purpose means keeping it, even if it looked like a duplicate.
                changes[index].isSelected = true
            }
        }
        return Self.ordered(changes)
    }

    /// A parent title from the model, or, if it can't help, from the words the tasks share.
    /// Which sentences "these" reaches back to: from the instruction backwards while sentences hold
    /// only new tasks, stopping after the one that introduced the named parent ("I need to plan the
    /// Goa trip"), at anything else said in between ("I finished the wireframes"), or where the
    /// project changes. So in a longer note, "bundle these" means the run of tasks just before it.
    static func sentencesReferredBack(from directive: BundleDirective, after previousIndex: Int,
                                      tasks: [(sentence: Int, isNew: Bool, title: String, project: String?)]) -> Set<Int> {
        var included = Set<Int>()
        var groupProject: String??
        var sentence = directive.sentenceIndex
        while sentence > previousIndex {
            let here = tasks.filter { $0.sentence == sentence }
            if sentence != directive.sentenceIndex {
                if here.isEmpty || here.contains(where: { !$0.isNew }) { break }
                let projects = Set(here.map(\.project))
                if let groupProject, projects != [groupProject] { break }
            }
            included.insert(sentence)
            if !here.isEmpty, groupProject == nil { groupProject = .some(here[0].project) }
            if let name = directive.parentName, here.contains(where: { $0.isNew && covers(name, $0.title) }) { break }
            sentence -= 1
        }
        return included
    }

    private func umbrellaTitle(for titles: [String]) async throws -> String {
        let session = LanguageModelSession(model: Self.model, instructions: "You name a parent task for a group of related tasks.")
        if let response = try? await session.respond(
            to: "Tasks:\n" + titles.map { "- \($0)" }.joined(separator: "\n"),
            generating: UmbrellaTitle.self
        ) {
            let title = Self.cleanTitle(response.content.title)
            if !title.isEmpty { return title }
        }
        let counts = titles.flatMap { Array(Self.words($0)) }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        guard let shared = counts.filter({ $0.value >= 2 }).max(by: { $0.value < $1.value })?.key else { return "Grouped tasks" }
        return shared.prefix(1).uppercased() + shared.dropFirst() + " tasks"
    }

    /// The single open issue whose title covers a spoken name ("portfolio" → "Pick portfolio projects").
    static func onlyIssue(covering name: String, among issues: [LinearIssue]) -> LinearIssue? {
        let matching = issues.filter { covers(name, $0.title) }
        return matching.count == 1 ? matching[0] : bestIssue(for: name, among: issues)
    }

    /// Whether a phrase starts with an action ("pick", "writing"), per Apple's on-device tagger.
    static func startsWithVerb(_ text: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        guard let start = text.firstIndex(where: \.isLetter) else { return false }
        return tagger.tag(at: start, unit: .word, scheme: .lexicalClass).0 == .verb
    }

    /// Each parent followed by the sub-tasks created under it in this note.
    static func ordered(_ changes: [ProposedChange]) -> [ProposedChange] {
        var result: [ProposedChange] = []
        for change in changes where change.parentChangeID == nil && !isNested(change, in: changes) {
            result.append(change)
            result += changes.filter { isChild($0, of: change) }
        }
        result += changes.filter { change in !result.contains { $0.id == change.id } }
        return result
    }

    /// Whether `child` sits under `parent` in this note: a new parent, or an existing issue being changed here.
    static func isChild(_ child: ProposedChange, of parent: ProposedChange) -> Bool {
        if child.parentChangeID == parent.id { return true }
        guard child.parentChangeID == nil, let parentIssue = parent.existing, child.id != parent.id else { return false }
        return child.parent?.id == parentIssue.id
    }

    /// Whether a change shows indented under another card in this note.
    static func isNested(_ change: ProposedChange, in changes: [ProposedChange]) -> Bool {
        changes.contains { isChild(change, of: $0) }
    }

    /// One task from two: the model writes a title covering both; if it can't, they're joined.
    static func mergedTitle(_ first: String, _ second: String) async -> String {
        let session = LanguageModelSession(
            model: model,
            instructions: "Combine two tasks into one short task title, in imperative form, that keeps the specific words of both."
        )
        if let response = try? await session.respond(to: "Task 1: \(first)\nTask 2: \(second)", generating: UmbrellaTitle.self) {
            let title = cleanTitle(response.content.title)
            let kept = Double(words(title).intersection(words(first + " " + second)).count) / Double(max(words(title).count, 1))
            if !title.isEmpty, kept >= 0.6 { return title }
        }
        return first + " and " + second.prefix(1).lowercased() + second.dropFirst()
    }

    /// Whether `title` says nearly everything `name` does ("Plan the Goa trip" covers "Goa trip").
    static func covers(_ name: String, _ title: String) -> Bool {
        let nameWords = matchWords(name)
        guard !nameWords.isEmpty else { return false }
        return Double(nameWords.intersection(matchWords(title)).count) / Double(nameWords.count) >= 0.75
    }

    /// The open issue a spoken name most likely refers to: at least two shared words and no tie.
    /// One-word names ("health") are too vague to point at an existing issue.
    static func bestIssue(for name: String, among issues: [LinearIssue]) -> LinearIssue? {
        let nameWords = matchWords(name)
        guard !nameWords.isEmpty else { return nil }
        let needed = 2
        let scored = issues.map { (issue: $0, shared: nameWords.intersection(matchWords($0.title)).count) }
            .filter { $0.shared >= needed }
            .sorted { $0.shared > $1.shared }
        guard let best = scored.first, scored.dropFirst().first?.shared != best.shared else { return nil }
        return best.issue
    }

    /// Content words plus adjacent pairs joined, so "handoff" matches "hand off" and "checkup" "check up".
    static func matchWords(_ text: String) -> Set<String> {
        let raw = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let joined = zip(raw, raw.dropFirst()).map { $0 + $1 }.filter { $0.count >= 5 }
        return words(text).union(joined)
    }
}
