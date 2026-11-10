import Foundation

/// Applies reviewed voice-note changes to Linear. Needs an API key with Write access.
struct LinearWriter {
    let client: LinearClient

    init(apiKey: String) {
        client = LinearClient(apiKey: apiKey)
    }

    /// IDs needed to turn "done" / "this week" into Linear's workflow states and cycles.
    struct Context {
        struct Team {
            let id: String
            let key: String
            let activeCycleID: String?
            let nextCycleID: String?
            /// Sorted by position, like Linear's board columns.
            let states: [(id: String, type: String)]
            let projects: [(id: String, name: String)]
            let labels: [(id: String, name: String)]

            /// The first state of the matching type, e.g. the team's first "started" column for in progress.
            func stateID(for status: StatusChange) -> String? {
                let type: String
                switch status {
                case .unchanged: return nil
                case .todo: type = "unstarted"
                case .inProgress: type = "started"
                case .done: type = "completed"
                case .canceled: type = "canceled"
                }
                return states.first { $0.type == type }?.id
            }

            func cycleID(for placement: Placement) -> Any? {
                switch placement {
                case .unchanged: nil
                case .thisWeek: activeCycleID
                case .nextWeek: nextCycleID
                case .backlog: NSNull()
                }
            }
        }

        let viewerID: String
        let teams: [Team]
        let workspaceLabels: [(id: String, name: String)]

        /// Projects and labels for the planner to file new tasks with.
        func catalog(defaultTeamKey: String?) -> VoiceCatalog {
            VoiceCatalog(
                projects: teams.flatMap { team in team.projects.map { VoiceCatalog.Project(id: $0.id, name: $0.name, teamKey: team.key) } },
                labels: workspaceLabels.map { VoiceCatalog.Label(id: $0.id, name: $0.name, teamKey: nil) }
                    + teams.flatMap { team in team.labels.map { VoiceCatalog.Label(id: $0.id, name: $0.name, teamKey: team.key) } },
                defaultTeamKey: defaultTeamKey ?? teams.first?.key
            )
        }
    }

    /// Loads teams, projects and labels as three small queries in parallel. One combined query
    /// (teams × states × projects × labels) goes over Linear's per-query complexity limit.
    func loadContext() async throws -> Context {
        async let teamsPayload = client.execute(Self.teamsQuery, as: TeamsPayload.self)
        async let projectsPayload = client.execute(Self.projectsQuery, as: ProjectsPayload.self)
        async let labelsPayload = client.execute(Self.labelsQuery, as: LabelsPayload.self)
        let (teamData, projectData, labelData) = try await (teamsPayload, projectsPayload, labelsPayload)

        let teamKeys = Set(teamData.viewer.teams.nodes.map(\.key))
        let labels = labelData.issueLabels.nodes.filter { !$0.isGroup }
        let teams = teamData.viewer.teams.nodes.map { team in
            Context.Team(
                id: team.id, key: team.key,
                activeCycleID: team.activeCycle?.id,
                nextCycleID: team.cycles.nodes.first?.id,
                states: team.states.nodes.sorted { $0.position < $1.position }.map { ($0.id, $0.type) },
                // A project shared by several of your teams is listed under the first of them.
                projects: projectData.projects.nodes
                    .filter { $0.teams.nodes.first { teamKeys.contains($0.key) }?.key == team.key }
                    .map { ($0.id, $0.name) },
                labels: labels.filter { $0.team?.key == team.key }.map { ($0.id, $0.name) }
            )
        }
        return Context(
            viewerID: teamData.viewer.id,
            teams: teams,
            workspaceLabels: labels.filter { $0.team == nil }.map { ($0.id, $0.name) }
        )
    }

    /// Applies the changes one by one and returns how many succeeded. Stops at the first failure,
    /// so the error names the change that didn't go through.
    func apply(_ changes: [ProposedChange], context: Context) async throws -> Int {
        var applied = 0
        // New parents are created first, so their sub-tasks can point at the new issue.
        var created: [UUID: String] = [:]
        let ordered = changes.filter { $0.parentChangeID == nil } + changes.filter { $0.parentChangeID != nil }
        for change in ordered {
            do {
                if let id = try await apply(change, context: context, parentID: change.parentChangeID.flatMap { created[$0] }) {
                    created[change.id] = id
                }
                applied += 1
            } catch {
                throw ApplyError(applied: applied, failed: change.headline, underlying: error)
            }
        }
        return applied
    }

    /// Applies one change and returns the new issue's ID when it created one.
    /// - Parameter parentID: The issue created for this change's new parent, if any.
    private func apply(_ change: ProposedChange, context: Context, parentID: String?) async throws -> String? {
        let parentID = parentID ?? change.parent?.id
        guard let issue = change.existing else {
            guard let team = context.teams.first(where: { $0.key == change.resolvedTeamKey }) ?? context.teams.first else {
                throw LinearError.graphQL("You're not a member of any Linear team.")
            }
            var input: [String: Any] = ["teamId": team.id, "title": change.title, "assigneeId": context.viewerID]
            if let summary = change.summary { input["description"] = summary }
            if let project = change.project, project.teamKey == team.key { input["projectId"] = project.id }
            if let parentID { input["parentId"] = parentID }
            let labelIDs = change.labels.filter { $0.teamKey == nil || $0.teamKey == team.key }.map(\.id)
            if !labelIDs.isEmpty { input["labelIds"] = labelIDs }
            fill(&input, from: change, team: team)
            return try await mutate(Self.createMutation, variables: ["input": input], key: "issueCreate")
        }

        guard let team = context.teams.first(where: { $0.key == issue.teamKey }) else {
            throw LinearError.graphQL("Couldn't find the team for \(issue.identifier).")
        }
        var input: [String: Any] = [:]
        fill(&input, from: change, team: team)
        if let parentID { input["parentId"] = parentID }  // moved under a parent
        if !input.isEmpty {
            try await mutate(Self.updateMutation, variables: ["id": issue.id, "input": input], key: "issueUpdate")
        }
        if let comment = change.comment {
            try await mutate(Self.commentMutation, variables: ["input": ["issueId": issue.id, "body": comment]], key: "commentCreate")
        }
        return nil
    }

    private func fill(_ input: inout [String: Any], from change: ProposedChange, team: Context.Team) {
        if let stateID = team.stateID(for: change.status) { input["stateId"] = stateID }
        if let dueDate = change.dueDate { input["dueDate"] = dueDate }
        if let priority = change.priority { input["priority"] = priority }
        if let cycleID = team.cycleID(for: change.placement) { input["cycleId"] = cycleID }
    }

    /// Runs a mutation and returns the affected issue's ID, when the mutation reports one.
    @discardableResult
    private func mutate(_ mutation: String, variables: [String: Any], key: String) async throws -> String? {
        let payload = try await client.execute(mutation, variables: variables, as: [String: MutationResult].self)
        guard let result = payload[key], result.success else { throw LinearError.graphQL("Linear didn't accept the change.") }
        return result.issue?.id
    }

    struct ApplyError: LocalizedError {
        let applied: Int
        let failed: String
        let underlying: Error

        var errorDescription: String? {
            let reason = underlying.localizedDescription
            return applied == 0
                ? reason
                : "Applied \(applied), then “\(failed)” failed: \(reason)"
        }
    }

    // MARK: - GraphQL

    private static let teamsQuery = """
    query VoiceTeams {
      viewer {
        id
        teams(first: 25) {
          nodes {
            id key
            activeCycle { id }
            cycles(first: 1, filter: { isNext: { eq: true } }) { nodes { id } }
            states(first: 25) { nodes { id type position } }
          }
        }
      }
    }
    """

    private static let projectsQuery = """
    query VoiceProjects {
      projects(first: 100, filter: { completedAt: { null: true }, canceledAt: { null: true } }) {
        nodes { id name teams(first: 5) { nodes { key } } }
      }
    }
    """

    private static let labelsQuery = """
    query VoiceLabels {
      issueLabels(first: 200) { nodes { id name isGroup team { key } } }
    }
    """

    private static let createMutation = """
    mutation VoiceCreate($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id } } }
    """

    private static let updateMutation = """
    mutation VoiceUpdate($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success } }
    """

    private static let commentMutation = """
    mutation VoiceComment($input: CommentCreateInput!) { commentCreate(input: $input) { success } }
    """
}

private struct MutationResult: Decodable {
    struct IssueRef: Decodable { let id: String }
    let success: Bool
    let issue: IssueRef?
}

private struct TeamsPayload: Decodable {
    struct Viewer: Decodable {
        let id: String
        let teams: Connection<TeamNode>
    }
    struct TeamNode: Decodable {
        struct Ref: Decodable { let id: String }
        struct State: Decodable {
            let id: String
            let type: String
            let position: Double
        }
        let id: String
        let key: String
        let activeCycle: Ref?
        let cycles: Connection<Ref>
        let states: Connection<State>
    }
    let viewer: Viewer
}

private struct TeamKey: Decodable {
    let key: String
}

private struct ProjectsPayload: Decodable {
    struct Project: Decodable {
        let id: String
        let name: String
        let teams: Connection<TeamKey>
    }
    let projects: Connection<Project>
}

private struct LabelsPayload: Decodable {
    struct Label: Decodable {
        let id: String
        let name: String
        let isGroup: Bool
        let team: TeamKey?
    }
    let issueLabels: Connection<Label>
}
