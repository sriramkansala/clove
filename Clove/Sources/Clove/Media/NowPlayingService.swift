import AppKit
import Combine
import Foundation
import SwiftUI

enum PlayerApp: String {
    case music = "com.apple.Music"
    case spotify = "com.spotify.client"

    var notificationName: String {
        switch self {
        case .music: return "com.apple.Music.playerInfo"
        case .spotify: return "com.spotify.client.PlaybackStateChanged"
        }
    }

    var refreshScript: String {
        switch self {
        case .music:
            return """
            tell application "Music"
              if player state is stopped then return {"stopped"}
              set t to current track
              return {player state as text, (persistent ID of t) as text, name of t, artist of t, album of t, duration of t, player position}
            end tell
            """
        case .spotify:
            return """
            tell application "Spotify"
              if player state is stopped then return {"stopped"}
              set t to current track
              return {player state as text, (id of t) as text, name of t, artist of t, album of t, duration of t, player position}
            end tell
            """
        }
    }

    var artworkScript: String {
        switch self {
        case .music:
            return "tell application \"Music\" to return raw data of artwork 1 of current track"
        case .spotify:
            return "tell application \"Spotify\" to return artwork url of current track"
        }
    }

    func controlScript(_ verb: String) -> String {
        switch self {
        case .music: return "tell application \"Music\" to \(verb)"
        case .spotify: return "tell application \"Spotify\" to \(verb)"
        }
    }

    func seekScript(_ seconds: Int) -> String {
        switch self {
        case .music: return "tell application \"Music\" to set player position to \(seconds)"
        case .spotify: return "tell application \"Spotify\" to set player position to \(seconds)"
        }
    }
}

struct Track: Equatable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var app: PlayerApp
}

@MainActor
final class NowPlayingService: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accentColor: Color = .white

    private var positionAnchor: TimeInterval = 0
    private var positionAnchorDate: Date = .distantPast

    private let dnc = DistributedNotificationCenter.default()
    private var timer: Timer?
    private var artworkTaskID = 0
    /// Apps with a refresh script queued or running; a refresh requested meanwhile is coalesced.
    private var refreshInFlight: Set<PlayerApp> = []
    private var refreshAgain: Set<PlayerApp> = []
    /// Apps the user refused automation permission for (error -1743); not scripted again this session.
    private var deniedApps: Set<PlayerApp> = []

    init() {
        dnc.addObserver(
            self,
            selector: #selector(musicChanged(_:)),
            name: NSNotification.Name(PlayerApp.music.notificationName),
            object: nil
        )
        dnc.addObserver(
            self,
            selector: #selector(spotifyChanged(_:)),
            name: NSNotification.Name(PlayerApp.spotify.notificationName),
            object: nil
        )

        refresh(app: .music)
        refresh(app: .spotify)

        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                if let current = self.track?.app {
                    self.refresh(app: current)
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit {
        dnc.removeObserver(self)
        timer?.invalidate()
    }

    // MARK: - Position

    func position(at date: Date) -> TimeInterval {
        guard let track else { return 0 }
        var value = positionAnchor + (isPlaying ? date.timeIntervalSince(positionAnchorDate) : 0)
        value = max(0, min(value, track.duration))
        return value
    }

    // MARK: - Notifications

    @objc private func musicChanged(_ note: Notification) {
        refresh(app: .music)
    }

    @objc private func spotifyChanged(_ note: Notification) {
        refresh(app: .spotify)
    }

    // MARK: - Refresh

    private func isRunning(_ app: PlayerApp) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: app.rawValue).isEmpty
    }

    private func refresh(app: PlayerApp) {
        guard isRunning(app), !deniedApps.contains(app) else {
            if track?.app == app {
                clearTrack()
            }
            return
        }
        guard !refreshInFlight.contains(app) else {
            refreshAgain.insert(app)
            return
        }
        refreshInFlight.insert(app)
        AppleScriptRunner.run(app.refreshScript) { [weak self] outcome in
            guard let self else { return }
            self.refreshInFlight.remove(app)
            self.apply(outcome, from: app)
            if self.refreshAgain.remove(app) != nil {
                self.refresh(app: app)
            }
        }
    }

    private func apply(_ outcome: AppleScriptRunner.Outcome, from app: PlayerApp) {
        if outcome.errorNumber == -1743 {
            deniedApps.insert(app)
        }
        guard let descriptor = outcome.descriptor else {
            // Script failed (not authorised / not running). Treat as no track for this app.
            if track?.app == app {
                clearTrack()
            }
            return
        }

        let count = descriptor.numberOfItems
        guard count > 0 else {
            if track?.app == app { clearTrack() }
            return
        }

        let state = descriptor.atIndex(1)?.stringValue ?? ""

        if count == 1 || state == "stopped" {
            // No track for this app. Only clear if we currently own the display.
            if track?.app == app { clearTrack() }
            return
        }

        guard count >= 7 else {
            if track?.app == app { clearTrack() }
            return
        }

        let id = descriptor.atIndex(2)?.stringValue ?? ""
        let title = descriptor.atIndex(3)?.stringValue ?? ""
        let artist = descriptor.atIndex(4)?.stringValue ?? ""
        let album = descriptor.atIndex(5)?.stringValue ?? ""
        var duration = descriptor.atIndex(6)?.doubleValue ?? 0
        let position = descriptor.atIndex(7)?.doubleValue ?? 0

        // Spotify reports duration in milliseconds.
        if app == .spotify, duration > 36_000 {
            duration /= 1000
        }

        let newTrack = Track(
            id: id,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            app: app
        )

        let previousID = track?.id
        let wasPlaying = isPlaying
        if state == "playing" {
            // A playing app always takes over the display.
            if track != newTrack {
                track = newTrack
            }
            isPlaying = true

            // Anchor position only for the adopted track.
            let now = Date()
            positionAnchor = max(0, min(position, duration))
            positionAnchorDate = now
        } else if state == "paused" {
            // A paused app only takes over if nothing is actively playing.
            if !wasPlaying || track?.app == app {
                if track != newTrack {
                    track = newTrack
                }
                isPlaying = false

                // Anchor position only for the adopted track.
                let now = Date()
                positionAnchor = max(0, min(position, duration))
                positionAnchorDate = now
            }
        } else {
            // Unknown state: ignore.
            return
        }

        // Reload artwork only when the adopted track actually changed (not on play/pause).
        if track?.app == app, previousID != newTrack.id {
            loadArtwork(for: app)
        }
    }

    private func clearTrack() {
        track = nil
        artwork = nil
        isPlaying = false
        accentColor = .white
    }

    // MARK: - Artwork

    private func loadArtwork(for app: PlayerApp) {
        artwork = nil
        accentColor = .white

        let id = artworkTaskID &+ 1
        artworkTaskID = id

        switch app {
        case .music:
            AppleScriptRunner.run(app.artworkScript) { [weak self] outcome in
                guard let descriptor = outcome.descriptor,
                      let image = NSImage(data: descriptor.data) else { return }
                self?.applyArtwork(image, taskID: id)
            }

        case .spotify:
            AppleScriptRunner.run(app.artworkScript) { [weak self] outcome in
                guard let urlString = outcome.descriptor?.stringValue,
                      let url = URL(string: urlString) else { return }
                self?.downloadArtwork(from: url, taskID: id)
            }
        }
    }

    private func downloadArtwork(from url: URL, taskID id: Int) {
        Task { [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = NSImage(data: data) else { return }
                await MainActor.run {
                    self?.applyArtwork(image, taskID: id)
                }
            } catch {
                // Ignore download failures.
            }
        }
    }

    private func applyArtwork(_ image: NSImage, taskID: Int) {
        guard taskID == artworkTaskID else { return }
        artwork = image
        accentColor = ArtworkColor.accent(for: image)
    }

    // MARK: - Controls

    func playPause() {
        guard let app = track?.app else { return }
        AppleScriptRunner.run(app.controlScript("playpause"))

        let wasPlaying = isPlaying
        if !wasPlaying {
            // Starting playback: adopt this app's track and anchor now.
            if let t = track {
                positionAnchor = max(0, min(positionAnchor, t.duration))
            }
        }
        isPlaying = !wasPlaying
        positionAnchorDate = Date()

        resync(after: 0.3)
    }

    func next() {
        guard let app = track?.app else { return }
        AppleScriptRunner.run(app.controlScript("next track"))
        resync(after: 0.3)
    }

    func previous() {
        guard let app = track?.app else { return }
        AppleScriptRunner.run(app.controlScript("previous track"))
        resync(after: 0.3)
    }

    func seek(to seconds: TimeInterval) {
        guard let app = track?.app else { return }
        let clamped = max(0, min(seconds, track?.duration ?? seconds))
        AppleScriptRunner.run(app.seekScript(Int(clamped)))

        positionAnchor = clamped
        positionAnchorDate = Date()

        resync(after: 0.3)
    }

    func openPlayerApp() {
        guard let app = track?.app,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.rawValue) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }

    private func resync(after delay: TimeInterval) {
        guard let app = track?.app else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.track?.app == app {
                    self.refresh(app: app)
                }
            }
        }
    }
}
