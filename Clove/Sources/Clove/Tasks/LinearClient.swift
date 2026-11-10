import Foundation

enum LinearError: LocalizedError {
    case unauthorized
    case http(Int)
    case graphQL(String)
    case emptyResponse
    case readOnlyKey

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Linear rejected the API key."
        case .readOnlyKey: "Your Linear API key is read-only. Create one with Write access in Linear and replace it in Settings."
        case .http(let code): "Linear returned HTTP \(code)."
        case .graphQL(let message): message
        case .emptyResponse: "Linear returned no data."
        }
    }
}

/// Minimal client for Linear's GraphQL API, authenticated with a personal API key.
struct LinearClient {
    let apiKey: String

    private static let endpoint = URL(string: "https://api.linear.app/graphql")!

    private static let query = """
    query CloveIssues {
      viewer {
        name
        displayName
        assignedIssues(first: 100, orderBy: updatedAt, filter: { state: { type: { nin: ["completed", "canceled"] } } }) {
          nodes {
            id identifier title url priority dueDate
            state { name type color position }
            team { id key }
            cycle { id startsAt }
            project { id name }
          }
        }
        teams(first: 50) {
          nodes {
            id name key
            activeCycle { id number name startsAt endsAt progress }
          }
        }
      }
    }
    """

    /// Fetches the viewer's open assigned issues plus the active cycle of `preferredTeamID`,
    /// or, when that's nil or has no active cycle, of the team holding most of those issues.
    func fetch(preferredTeamID: String?) async throws -> (snapshot: LinearSnapshot, teams: [LinearTeam]) {
        let payload = try await execute(Self.query, as: IssuesPayload.self)
        guard let viewer = payload.viewer else { throw LinearError.emptyResponse }
        return Self.makeSnapshot(from: viewer, preferredTeamID: preferredTeamID)
    }

    /// Runs a GraphQL query or mutation and decodes its `data`. Use `NSNull()` in `variables` for null.
    func execute<Payload: Decodable>(_ query: String, variables: [String: Any] = [:], as: Payload.Type) async throws -> Payload {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw LinearError.unauthorized }

        let decoded: GraphQLResponse<Payload>
        do {
            decoded = try Self.decoder.decode(GraphQLResponse<Payload>.self, from: data)
        } catch {
            throw status == 200 ? error : LinearError.http(status)
        }

        if let message = decoded.errors?.first?.message {
            // Linear answers a bad key with HTTP 400 and an "Authentication required" error.
            if message.localizedCaseInsensitiveContains("authenticat") { throw LinearError.unauthorized }
            if ["scope", "permission", "forbidden", "not authorized"].contains(where: message.localizedCaseInsensitiveContains) {
                throw LinearError.readOnlyKey
            }
            throw LinearError.graphQL(message)
        }
        guard let payload = decoded.data else { throw LinearError.emptyResponse }
        return payload
    }

    private static func makeSnapshot(from viewer: Viewer, preferredTeamID: String?) -> (snapshot: LinearSnapshot, teams: [LinearTeam]) {
        let nodes = viewer.assignedIssues.nodes
        let teamsWithCycle = viewer.teams.nodes.filter { $0.activeCycle != nil }
        let openIssuesByTeam = Dictionary(grouping: nodes, by: \.team.id).mapValues(\.count)
        let cycleTeam = teamsWithCycle.first { $0.id == preferredTeamID }
            ?? teamsWithCycle.max { (openIssuesByTeam[$0.id] ?? 0) < (openIssuesByTeam[$1.id] ?? 0) }
        let activeCycleID = cycleTeam?.activeCycle?.id
        let now = Date()

        let issues = nodes.enumerated()
            .compactMap { index, node -> (Int, LinearIssue)? in
                guard let url = URL(string: node.url) else { return nil }
                let issue = LinearIssue(
                    id: node.id, identifier: node.identifier, title: node.title, url: url,
                    priority: Int(node.priority),
                    stateName: node.state.name, stateType: node.state.type,
                    stateColor: node.state.color, statePosition: node.state.position,
                    teamKey: node.team.key,
                    dueDate: node.dueDate,
                    inCurrentCycle: activeCycleID != nil && node.cycle?.id == activeCycleID,
                    inUpcomingCycle: node.cycle.map { $0.startsAt > now } ?? false,
                    projectID: node.project?.id,
                    projectName: node.project?.name
                )
                return (index, issue)
            }
            // API order (most recently updated) is the final tiebreak.
            .sorted { a, b in
                (a.1.stateRank, a.1.statePosition, a.1.priorityRank, a.0) < (b.1.stateRank, b.1.statePosition, b.1.priorityRank, b.0)
            }
            .map(\.1)

        let cycle = cycleTeam.flatMap { team in
            team.activeCycle.map { active in
                CycleSummary(
                    teamName: team.name, teamKey: team.key,
                    number: Int(active.number), name: active.name,
                    startsAt: active.startsAt, endsAt: active.endsAt,
                    progress: active.progress
                )
            }
        }

        let snapshot = LinearSnapshot(
            viewerName: viewer.displayName.isEmpty ? viewer.name : viewer.displayName,
            issues: issues,
            cycle: cycle,
            fetchedAt: Date()
        )
        let teams = viewer.teams.nodes.map {
            LinearTeam(id: $0.id, name: $0.name, key: $0.key, hasActiveCycle: $0.activeCycle != nil)
        }
        return (snapshot, teams)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unrecognized date \(string)"))
        }
        return decoder
    }()
}

// MARK: - GraphQL response shapes

private struct GraphQLResponse<Payload: Decodable>: Decodable {
    struct GraphQLError: Decodable { let message: String }

    let data: Payload?
    let errors: [GraphQLError]?
}

private struct IssuesPayload: Decodable {
    let viewer: Viewer?
}

struct Connection<Node: Decodable>: Decodable {
    let nodes: [Node]
}

private struct Viewer: Decodable {
    let name: String
    let displayName: String
    let assignedIssues: Connection<IssueNode>
    let teams: Connection<TeamNode>
}

private struct IssueNode: Decodable {
    struct State: Decodable {
        let name: String
        let type: String
        let color: String
        let position: Double
    }
    struct TeamRef: Decodable {
        let id: String
        let key: String
    }
    struct CycleRef: Decodable {
        let id: String
        let startsAt: Date
    }

    let id: String
    let identifier: String
    let title: String
    let url: String
    let priority: Double
    /// "yyyy-MM-dd", in the workspace's calendar.
    let dueDate: String?
    let state: State
    let team: TeamRef
    let cycle: CycleRef?
    let project: ProjectRef?
}

private struct ProjectRef: Decodable {
    let id: String
    let name: String
}

private struct TeamNode: Decodable {
    struct Cycle: Decodable {
        let id: String
        let number: Double
        let name: String?
        let startsAt: Date
        let endsAt: Date
        let progress: Double
    }

    let id: String
    let name: String
    let key: String
    let activeCycle: Cycle?
}
