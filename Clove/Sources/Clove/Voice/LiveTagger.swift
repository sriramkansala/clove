import Foundation
import NaturalLanguage
import SwiftUI

/// A chip saying what part of a voice note was understood as. Status, urgency and comments show
/// as icon-only chips; the rest show their text.
struct VoiceTag: Hashable, Identifiable {
    enum Kind: Int {
        case status, date, priority, project, sprint, topic, person, parent, comment
    }

    let kind: Kind
    let text: String
    /// Draws attention: a due date within a day shows in red.
    var emphasized = false
    var id: String { "\(kind.rawValue)-\(text)" }

    // Status words used on chips.
    static let new = "New"
    static let done = "Done"
    static let inProgress = "In Progress"
    static let canceled = "Cancel"
    static let reopened = "Reopen"
    static let backlog = "Backlog"
    static let todo = "Todo"

    var iconOnly: Bool {
        switch kind {
        case .status, .comment: true
        case .priority: text == "Urgent"
        default: false
        }
    }

    var color: Color {
        switch kind {
        case .status:
            switch text {
            case Self.done: .green
            case Self.inProgress: .orange
            case Self.canceled: .red
            default: .secondary
            }
        case .date: emphasized ? .red : .secondary
        case .priority: text == "Urgent" ? .red : text == "High" ? .orange : .secondary
        case .project: .linearAccent
        case .sprint: .indigo
        case .topic: .teal
        case .person: .pink
        case .parent, .comment: .secondary
        }
    }

    var symbol: String {
        switch kind {
        case .status:
            switch text {
            case Self.done: "checkmark.circle.fill"
            case Self.inProgress: "circle.righthalf.filled"
            case Self.canceled: "xmark.circle.fill"
            case Self.todo, Self.reopened: "circle"
            default: "circle.dashed"  // new, backlog
            }
        case .date: "calendar"
        case .priority: text == "Urgent" ? "light.beacon.max.fill" : "flag.fill"
        case .project: "folder.fill"
        case .sprint: "arrow.forward.circle.fill"
        case .topic: "number"
        case .person: "person.fill"
        case .parent: "arrow.turn.down.right"
        case .comment: "bubble.left"
        }
    }

    /// "Fri, Oct 2", red when it's due today, tomorrow or earlier.
    static func due(_ day: String) -> VoiceTag? {
        guard let date = VoicePlanner.dayFormatter.date(from: day) else { return nil }
        let soon = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: Date())) ?? date
        return VoiceTag(kind: .date, text: date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), emphasized: date < soon)
    }

    static func priority(_ value: Int) -> VoiceTag {
        VoiceTag(kind: .priority, text: ["", "Urgent", "High", "Medium", "Low"][value])
    }

    static func sprint(_ placement: Placement) -> VoiceTag? {
        switch placement {
        case .unchanged: nil
        case .thisWeek: VoiceTag(kind: .sprint, text: "This Week")
        case .nextWeek: VoiceTag(kind: .sprint, text: "Next Week")
        case .backlog: VoiceTag(kind: .sprint, text: "Backlog")
        }
    }

    static func status(_ change: StatusChange) -> VoiceTag? {
        switch change {
        case .unchanged: nil
        case .todo: VoiceTag(kind: .status, text: reopened)
        case .inProgress: VoiceTag(kind: .status, text: inProgress)
        case .done: VoiceTag(kind: .status, text: done)
        case .canceled: VoiceTag(kind: .status, text: canceled)
        }
    }

    /// An existing issue's current state, shown muted when the note doesn't change it.
    static func current(_ issue: LinearIssue) -> VoiceTag {
        switch issue.stateType {
        case "started": VoiceTag(kind: .status, text: "\(inProgress) (now)")
        case "backlog", "triage": VoiceTag(kind: .status, text: backlog)
        default: VoiceTag(kind: .status, text: todo)
        }
    }
}

extension VoiceTag.Kind {
    /// The color a word of this kind gets in the live transcript.
    var highlight: Color {
        switch self {
        case .status: .green
        case .date: .blue
        case .priority: .orange
        case .project: .linearAccent
        case .sprint: .indigo
        case .topic: .teal
        case .person: .pink
        case .parent, .comment: .secondary
        }
    }
}

/// A task the note seems to be about, shown while the user is still talking.
struct LiveDraft: Identifiable, Equatable {
    enum Kind {
        case newTask
        case update
        case note
        /// A "bundle these under …" instruction.
        case bundle
    }

    let id: String
    let kind: Kind
    let title: String
    var tags: [VoiceTag]
    /// The spoken sentence it came from, for groupings that refer back ("bundle these").
    var sentence = 0
}

struct LiveTagging {
    var transcript = AttributedString()
    var drafts: [LiveDraft] = []
}

/// Tags a transcript as it's spoken: highlights the words that name a project, topic, date,
/// priority, sprint, status or person, and groups them into draft tasks. It uses the same rules
/// as the planner, so the preview matches what the review will propose, and runs instantly
/// without the model.
enum LiveTagger {
    static func tag(_ transcript: String, issues: [LinearIssue], catalog: VoiceCatalog, today: Date = Date()) -> LiveTagging {
        LiveTagging(
            transcript: highlighted(transcript, catalog: catalog),
            drafts: drafts(in: transcript, issues: issues, catalog: catalog, today: today)
        )
    }

    // MARK: - Draft tasks

    private static func drafts(in transcript: String, issues: [LinearIssue], catalog: VoiceCatalog, today: Date) -> [LiveDraft] {
        var drafts: [(draft: LiveDraft, sentence: Int)] = []
        var seenTitles = Set<String>()
        var directives: [BundleDirective] = []
        for (index, sentence) in VoicePlanner.sentences(of: transcript).enumerated() {
            let directive = BundleDirective.parse(sentence, index: index)
            if let directive { directives.append(directive) }
            // Tasks named in a grouping instruction come from its list, not from its wording.
            var pieces = pieces(of: sentence).compactMap(BundleDirective.withoutInstructions)
            if case .listed(let items)? = directive?.children { pieces = items }
            for piece in pieces where !VoicePlanner.words(piece).isEmpty {
                guard let draft = draft(for: piece, transcript: transcript, issues: issues, catalog: catalog, today: today)
                        ?? listedDraft(piece, directive: directive),
                      seenTitles.insert(draft.title.lowercased()).inserted
                else { continue }
                drafts.append((draft, index))
            }
        }

        // Show each grouping: a card for the instruction, and a "sub-task of" chip on what it groups.
        var previous = -1
        for (position, directive) in directives.enumerated() {
            let next = position + 1 < directives.count ? directives[position + 1].sentenceIndex : Int.max
            let loose = drafts.indices.filter { drafts[$0].draft.kind == .newTask && !drafts[$0].draft.tags.contains { $0.kind == .parent } }
            var grouped: [Int]
            switch directive.children {
            case .before:
                let tasks = drafts.filter { $0.draft.kind != .bundle }.map { entry in
                    (sentence: entry.sentence, isNew: entry.draft.kind == .newTask, title: entry.draft.title,
                     project: entry.draft.tags.first { $0.kind == .project }?.text)
                }
                let inScope = VoicePlanner.sentencesReferredBack(from: directive, after: previous, tasks: tasks)
                grouped = loose.filter { inScope.contains(drafts[$0].sentence) }
                if grouped.isEmpty { grouped = loose.filter { drafts[$0].sentence > directive.sentenceIndex && drafts[$0].sentence < next } }
            case .after:
                grouped = loose.filter { drafts[$0].sentence > directive.sentenceIndex && drafts[$0].sentence < next }
            case .last(let count):
                grouped = Array(loose.filter { drafts[$0].sentence <= directive.sentenceIndex }.suffix(count))
            case .listed:
                grouped = loose.filter { drafts[$0].sentence == directive.sentenceIndex }
            }
            previous = directive.sentenceIndex
            let parentName = directive.parentName ?? "a new parent"
            // "Under the Goa trip" after "plan the Goa trip": that task is the parent.
            let parentIndex = directive.parentName.flatMap { name in grouped.first { VoicePlanner.covers(name, drafts[$0].draft.title) } }
            for index in grouped where index != parentIndex {
                drafts[index].draft.tags.insert(VoiceTag(kind: .parent, text: parentIndex.map { drafts[$0].draft.title } ?? parentName), at: 1)
            }
            let count = grouped.count - (parentIndex == nil ? 0 : 1)
            let card = LiveDraft(
                id: "bundle-\(directive.sentenceIndex)",
                kind: .bundle,
                title: directive.parentName.map { "Group under “\($0)”" } ?? "Group as sub-tasks",
                tags: count > 0 ? [VoiceTag(kind: .parent, text: count == 1 ? "1 sub-task" : "\(count) sub-tasks")] : []
            )
            drafts.append((card, directive.sentenceIndex))
        }
        return drafts.sorted { $0.sentence < $1.sentence }.map(\.draft)
    }

    /// A task named in a grouping instruction's list ("put exporting the files and … under X").
    private static func listedDraft(_ item: String, directive: BundleDirective?) -> LiveDraft? {
        guard directive != nil else { return nil }
        let title = VoicePlanner.cleanTitle(item)
        guard !title.isEmpty else { return nil }
        return LiveDraft(id: "newTask-\(title.lowercased())", kind: .newTask, title: title,
                         tags: [VoiceTag(kind: .status, text: VoiceTag.new)])
    }

    private static func draft(for piece: String, transcript: String, issues: [LinearIssue], catalog: VoiceCatalog, today: Date) -> LiveDraft? {
        let cues = VoicePlanner.Said(request: piece, transcript: transcript)
        let pieceWords = VoicePlanner.words(piece)
        let best = issues
            .map { (issue: $0, shared: pieceWords.intersection(VoicePlanner.words($0.title)).count) }
            .filter { $0.shared > 0 }
            .max { $0.shared < $1.shared }?
            .issue

        let status = cues.status(for: best?.title)
        let placement = cues.placement
        let date = VoicePlanner.dueDate(in: cues.context, today: today)
        let describesChange = status != .unchanged || placement != .unchanged

        var tags: [VoiceTag] = []
        var project: String?
        let kind: LiveDraft.Kind
        let title: String
        if let best, describesChange, !cues.asksForNewTaskHere {
            kind = .update
            title = best.title
            tags.append(VoiceTag.status(status) ?? VoiceTag.current(best))
            project = best.projectName
        } else if let best, cues.wantsNote, !cues.asksForNewTaskHere {
            kind = .note
            title = best.title
            tags.append(VoiceTag(kind: .comment, text: "Comment"))
            project = best.projectName
        } else if cues.asksForNewTaskHere {
            kind = .newTask
            title = VoicePlanner.cleanTitle(piece)
            guard !title.isEmpty else { return nil }
            tags.append(VoiceTag(kind: .status, text: VoiceTag.new))
            let parent = VoicePlanner.containing(title, among: issues)
            if let parent { tags.append(VoiceTag(kind: .parent, text: parent.title)) }
            project = parent?.projectName ?? VoicePlanner.project(mentionedIn: cues.scope, catalog: catalog)?.name
        } else {
            return nil
        }

        if let date, let chip = VoiceTag.due(date) { tags.append(chip) }
        if let priority = cues.priority { tags.append(.priority(priority)) }
        if let project { tags.append(VoiceTag(kind: .project, text: project)) }
        if let sprint = VoiceTag.sprint(placement) { tags.append(sprint) }
        tags += VoicePlanner.labels(mentionedIn: cues.context, catalog: catalog, teamKey: nil).map { VoiceTag(kind: .topic, text: $0.name) }
        tags += names(in: piece, excluding: catalog).filter { $0.kind == .person }

        return LiveDraft(id: "\(kind)-\(title.lowercased())", kind: kind, title: title, tags: tags)
    }

    /// A sentence's separate asks: split at commas and "and", keeping lead-ins ("For the Atlas
    /// handoff, …") and qualifiers ("…, it's urgent") with the part they belong to.
    private static func pieces(of sentence: String) -> [String] {
        var parts: [String] = []
        for raw in sentence.components(separatedBy: CharacterSet(charactersIn: ",;:")) {
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if let last = parts.last, VoicePlanner.words(part).isEmpty || isLeadIn(last) {
                parts[parts.count - 1] = last + ", " + part
            } else {
                parts.append(part)
            }
        }
        return parts.flatMap(VoicePlanner.splitCompound)
    }

    private static func isLeadIn(_ text: String) -> Bool {
        let lower = text.lowercased()
        return VoicePlanner.contextLeadIns.contains { lower.hasPrefix($0) }
            && !VoicePlanner.Said.newTaskPhrases.contains { lower.contains($0) }
            && VoicePlanner.words(text).count <= 3
    }

    // MARK: - Highlighted transcript

    private typealias Span = (range: NSRange, kind: VoiceTag.Kind)

    private static func highlighted(_ transcript: String, catalog: VoiceCatalog) -> AttributedString {
        let spans = nonOverlapping(spans(in: transcript, catalog: catalog))
        let text = transcript as NSString
        var result = AttributedString()
        var cursor = 0
        for span in spans {
            if span.range.location > cursor {
                result += AttributedString(text.substring(with: NSRange(location: cursor, length: span.range.location - cursor)))
            }
            let color = span.kind.highlight
            var word = AttributedString(text.substring(with: span.range))
            word.foregroundColor = color
            word.backgroundColor = color.opacity(0.16)
            word.font = .system(size: 15, weight: .semibold)
            result += word
            cursor = span.range.location + span.range.length
        }
        if cursor < text.length {
            result += AttributedString(text.substring(from: cursor))
        }
        return result
    }

    private static func spans(in transcript: String, catalog: VoiceCatalog) -> [Span] {
        let cues = VoicePlanner.Said.self
        var spans: [Span] = []
        func mark(_ phrases: [String], as kind: VoiceTag.Kind) {
            for phrase in phrases {
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
                for match in regex.matches(in: transcript, range: NSRange(location: 0, length: (transcript as NSString).length)) {
                    spans.append((match.range, kind))
                }
            }
        }
        mark(catalog.projects.map(\.name), as: .project)
        mark(catalog.labels.map(\.name), as: .topic)
        mark(cues.lowPriorityPhrases + cues.urgentPhrases + cues.highPriorityPhrases + cues.mediumPriorityPhrases, as: .priority)
        mark(cues.backlogPhrases + cues.nextWeekPhrases + cues.thisWeekPhrases, as: .sprint)
        // Status words only light up in sentences that report progress, not in "I need to get it done".
        let statusSentences = reportingSentences(in: transcript)
        let before = spans.count
        mark(cues.donePhrases + cues.startedPhrases + cues.canceledPhrases + cues.reopenedPhrases, as: .status)
        spans = Array(spans[..<before]) + spans[before...].filter { span in
            statusSentences.contains { NSIntersectionRange($0, span.range).length > 0 }
        }

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let text = transcript as NSString
            for match in detector.matches(in: transcript, range: NSRange(location: 0, length: text.length)) {
                let phrase = text.substring(with: match.range).lowercased()
                if !phrase.contains("week"), !phrase.contains("now") { spans.append((match.range, .date)) }
            }
        }
        for name in names(in: transcript, excluding: catalog) {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: name.text))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                for match in regex.matches(in: transcript, range: NSRange(location: 0, length: (transcript as NSString).length)) {
                    spans.append((match.range, name.kind))
                }
            }
        }
        return spans
    }

    private static func reportingSentences(in transcript: String) -> [NSRange] {
        var ranges: [NSRange] = []
        let text = transcript as NSString
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .bySentences) { sentence, range, _, _ in
            guard let sentence else { return }
            if VoicePlanner.Said(request: sentence, transcript: sentence).status(for: nil) != .unchanged {
                ranges.append(range)
            }
        }
        return ranges
    }

    private static let fillerWords: Set<String> = ["um", "umm", "uh", "uhh", "hmm", "er", "okay", "ok", "so", "yeah", "yes", "oh", "like", "well", "right", "alright", "hey", "anyway"]

    /// Longer spans win where highlights overlap ("not urgent" over "urgent").
    private static func nonOverlapping(_ spans: [Span]) -> [Span] {
        var kept: [Span] = []
        for span in spans.sorted(by: { $0.range.length > $1.range.length }) {
            if !kept.contains(where: { NSIntersectionRange($0.range, span.range).length > 0 }) {
                kept.append(span)
            }
        }
        return kept.sorted { $0.range.location < $1.range.location }
    }

    /// People ("Ravi") and organizations ("Figma") named in the text, using Apple's on-device
    /// language tagger. Organizations show as topics.
    private static func names(in text: String, excluding catalog: VoiceCatalog) -> [VoiceTag] {
        let known = Set((catalog.projects.map(\.name) + catalog.labels.map(\.name)).map { $0.lowercased() })
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var tags: [VoiceTag] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            let name = String(text[range])
            guard !known.contains(name.lowercased()), !fillerWords.contains(name.lowercased()), name.count > 2 else { return true }
            switch tag {
            case .personalName: tags.append(VoiceTag(kind: .person, text: name))
            case .organizationName: tags.append(VoiceTag(kind: .topic, text: name))
            default: break
            }
            return true
        }
        // The tagger doesn't know every name; a capitalized word right after "from", "with",
        // "ask", "call"… is a person too ("feedback from Ravi").
        let pattern = "\\b(?:from|with|ask|asked|call|email|message|ping|tell|meet|text|thank) ([A-Z][a-z]+)\\b"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: match.range(at: 1))
                if !known.contains(name.lowercased()) { tags.append(VoiceTag(kind: .person, text: name)) }
            }
        }
        var seen = Set<String>()
        return tags.filter { seen.insert($0.id).inserted }
    }
}

extension ProposedChange {
    /// The chips on a review card, in the same order and style as the live preview. Projects are
    /// left off: tasks still go into a project when one is named, but the review doesn't show it.
    var tags: [VoiceTag] {
        var tags: [VoiceTag] = []
        if let existing {
            tags.append(VoiceTag.status(status) ?? VoiceTag.current(existing))
        } else {
            tags.append(VoiceTag.status(status) ?? VoiceTag(kind: .status, text: VoiceTag.new))
        }
        if let dueDate, let chip = VoiceTag.due(dueDate) { tags.append(chip) }
        if let priority { tags.append(.priority(priority)) }
        if let sprint = VoiceTag.sprint(placement) { tags.append(sprint) }
        tags += labels.map { VoiceTag(kind: .topic, text: $0.name) }
        if let parent { tags.append(VoiceTag(kind: .parent, text: parent.title)) }
        if comment != nil { tags.append(VoiceTag(kind: .comment, text: "Comment")) }
        return tags
    }
}
