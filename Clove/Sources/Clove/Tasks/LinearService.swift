import AppKit
import Combine
import os

/// The user's open Linear issues: "This Week" is the active cycle, in Linear's "My issues"
/// order. Due dates across all open issues drive the "due today / overdue" reminders, and voice
/// notes read the key and the latest snapshot from here.
///
/// Uses a personal API key the user pastes into Settings (kept in the keychain). Refreshes every
/// few minutes and whenever the island opens.
@MainActor
final class LinearService: ObservableObject {
    enum Status: Equatable {
        case notConnected
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var status: Status
    /// Everything open and assigned to the viewer, plus the active cycle.
    @Published private(set) var snapshot: LinearSnapshot?

    /// This week: issues in the active cycle, in "My issues" order; with no cycle running, every
    /// open issue.
    var issues: [LinearIssue] {
        guard let snapshot else { return [] }
        return snapshot.cycle == nil ? snapshot.issues : snapshot.issues.filter(\.inCurrentCycle)
    }

    /// The key voice notes use to read and write Linear.
    var apiKey: String? { storedKey }

    /// Called with the issues that just became due today or overdue — all at once, so they make
    /// one reminder — at most once per issue per day, across relaunches.
    var onDue: (([LinearIssue]) -> Void)?

    var isConnected: Bool { status == .connected }

    nonisolated private static let keychainAccount = "linear-api-key"
    private static let announcedKey = "linearAnnounced"
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.clove.Clove", category: "Linear")
    private var storedKey: String?
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?

    init() {
        status = .notConnected
        // Read the key off the main thread: if macOS has to ask before handing it over, that
        // prompt must never freeze launch (it blocks the reading thread until answered).
        Task.detached(priority: .userInitiated) { [weak self] in
            #if DIRECT
            Keychain.migrateLegacyItem(LinearService.keychainAccount)
            #endif
            let key = Keychain.read(LinearService.keychainAccount)
            await self?.restore(key)
        }
    }

    private func restore(_ key: String?) {
        // The user may have connected in the meantime.
        guard let key, storedKey == nil else { return }
        storedKey = key
        status = .connected
        startUpdating()
    }

    /// Validates `key` with a real request and keeps it only if Linear accepts it.
    func connect(apiKey key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        status = .connecting
        refreshTask?.cancel()
        refreshTask = Task {
            defer { refreshTask = nil }
            do {
                let fetched = try await LinearClient(apiKey: key).fetch(preferredTeamID: nil).snapshot
                Keychain.write(key, account: Self.keychainAccount)
                storedKey = key
                status = .connected
                apply(fetched)
                startUpdating()
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        refreshTask?.cancel()
        refreshTimer?.invalidate()
        refreshTimer = nil
        Keychain.delete(Self.keychainAccount)
        storedKey = nil
        snapshot = nil
        status = .notConnected
    }

    func refresh() {
        guard let storedKey, refreshTask == nil || refreshTask?.isCancelled == true else { return }
        refreshTask = Task {
            defer { refreshTask = nil }
            do {
                apply(try await LinearClient(apiKey: storedKey).fetch(preferredTeamID: nil).snapshot)
                if status != .connected { status = .connected }
            } catch is CancellationError {
            } catch LinearError.unauthorized {
                status = .failed("Linear no longer accepts this API key. Paste a new one.")
            } catch {
                // Offline or a hiccup: keep the last snapshot and try again on the next tick.
                log.error("Linear refresh failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Takes a snapshot fetched elsewhere (e.g. by a voice note) so the island shows it at once.
    func adopt(_ fetched: LinearSnapshot) {
        apply(fetched)
    }

    func open(_ issue: LinearIssue) {
        NSWorkspace.shared.open(issue.url)
    }

    private func startUpdating() {
        refresh()
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func apply(_ fetched: LinearSnapshot) {
        // Compare without the fetch time, which changes on every refresh.
        var comparable = fetched
        comparable.fetchedAt = snapshot?.fetchedAt ?? fetched.fetchedAt
        if comparable != snapshot {
            snapshot = fetched
        }

        // Announce issues once a day when they are due today or overdue (any open issue, not
        // only this cycle's). Remembered in UserDefaults (issue id -> day announced) so
        // relaunching Clove does not repeat them.
        let now = Date()
        let calendar = Calendar.current
        var announced = (UserDefaults.standard.dictionary(forKey: Self.announcedKey) as? [String: Double] ?? [:])
            .filter { calendar.isDate(Date(timeIntervalSince1970: $0.value), inSameDayAs: now) }
        let fresh = fetched.issues.filter {
            ($0.isDueToday(at: now) || $0.isOverdue(at: now)) && announced[$0.id] == nil
        }
        for issue in fresh {
            announced[issue.id] = now.timeIntervalSince1970
        }
        UserDefaults.standard.set(announced, forKey: Self.announcedKey)
        if !fresh.isEmpty {
            onDue?(fresh)
        }
    }
}
