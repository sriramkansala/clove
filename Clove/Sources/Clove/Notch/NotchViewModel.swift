import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchViewModel: ObservableObject {
    enum IslandState {
        case collapsed
        case expanded
    }

    /// What the expanded island shows; only one page at a time.
    enum ExpandedPage {
        case player
        case calendar
        case tasks
        case system
    }

    @Published private(set) var state: IslandState = .collapsed
    @Published var notchSize: CGSize = .zero
    @Published var notchRect: CGRect = .zero
    @Published private(set) var showsMusicActivity = false
    /// A meeting with a join link starts soon (or just started) and reminders are on.
    @Published private(set) var showsMeetingActivity = false
    /// The tasks page shows more than two issues after "View more"; reset when the island closes.
    @Published private(set) var tasksExpanded = false
    /// A voice note is in progress: the island holds it, pinned open, sized to its content.
    @Published private(set) var voiceActive = false
    /// Natural height of the voice note's content, reported by `VoiceIslandView`.
    @Published private(set) var voiceHeight: CGFloat = 160
    @Published private(set) var page: ExpandedPage = .player
    /// Height of the page below the notch row; the expanded island hugs it.
    @Published private(set) var expandedContentHeight: CGFloat = IslandLayout.messageHeight

    let nowPlaying: NowPlayingService
    let activities: ActivityCenter
    let calendar: CalendarService
    let linear: LinearService
    let voice: VoiceNoteController
    let system: SystemMonitor
    let settings: AppSettings
    let compactWing: CGFloat = 42

    private let collapsedTopRadius: CGFloat = 6
    private let collapsedBottomRadius: CGFloat = 14

    var onStateChange: ((IslandState) -> Void)?
    var onOpenSettings: (() -> Void)?
    /// The low-battery notice was clicked.
    var onRequestLowPowerMode: (() -> Void)?
    /// A voice note opened the island: the window takes keyboard focus for ⏎ / Esc and renaming.
    var onVoicePresent: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pendingExpand: DispatchWorkItem?
    private var pendingCollapse: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var hideActivityWork: DispatchWorkItem?

    init(nowPlaying: NowPlayingService, activities: ActivityCenter, calendar: CalendarService,
         linear: LinearService, voice: VoiceNoteController, system: SystemMonitor, settings: AppSettings) {
        self.nowPlaying = nowPlaying
        self.activities = activities
        self.calendar = calendar
        self.linear = linear
        self.voice = voice
        self.system = system
        self.settings = settings

        // Only whether a note is running matters here; the note's own updates (waveform levels,
        // transcript) are observed by its view directly, so the island doesn't redraw for them.
        voice.$phase
            .map { $0 != .idle }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in self?.setVoiceActive(active) }
            .store(in: &cancellables)

        // Views read settings (e.g. whether to show the calendar) through the model.
        settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // The expanded height follows the page and what it shows.
        Publishers.Merge5(
            $page.map { _ in () },
            nowPlaying.$track.map { $0 != nil }.removeDuplicates().map { _ in () },
            calendar.objectWillChange.map { _ in () },
            linear.objectWillChange.map { _ in () },
            settings.$showCalendar.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            self?.objectWillChange.send()
            self?.updateContentHeight(animated: true)
        }
        .store(in: &cancellables)

        // "Meeting soon" beside the notch: grows in, shrinks out, like the other activities.
        Publishers.CombineLatest(calendar.$imminentMeeting.map { $0 != nil }, settings.$showMeetingReminders)
            .map { $0 && $1 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shows in
                guard let self, shows != self.showsMeetingActivity else { return }
                Motion.perform(shows ? Motion.islandGrow : Motion.islandShrink) {
                    self.showsMeetingActivity = shows
                }
            }
            .store(in: &cancellables)

        // `islandSize` reads `activities.current`, so republish when it changes.
        activities.$current
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        let trackPublisher = nowPlaying.$track.map { $0 != nil }
        let playingPublisher = nowPlaying.$isPlaying

        Publishers.CombineLatest3(trackPublisher, playingPublisher, settings.$showMusicActivity)
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasTrack, isPlaying, enabled in
                guard let self else { return }

                if hasTrack && isPlaying && enabled {
                    // Playing with a track: show immediately.
                    self.cancelPendingHide()
                    if !self.showsMusicActivity {
                        Motion.perform(Motion.islandGrow) {
                            self.showsMusicActivity = true
                        }
                    }
                } else if hasTrack && enabled {
                    // Paused: keep showing for 3 s before hiding.
                    self.scheduleHide(after: 3)
                } else {
                    // No track, or the music activity is turned off in settings.
                    self.cancelPendingHide()
                    if self.showsMusicActivity {
                        Motion.perform(Motion.islandShrink) {
                            self.showsMusicActivity = false
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        if let globalMonitor = globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor = localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }

    var islandSize: CGSize {
        switch state {
        case .collapsed:
            // A transient activity (charging, device connected) takes priority, then an
            // imminent meeting, then music.
            if activities.current != nil {
                return CGSize(width: notchSize.width + 2 * activities.wingWidth,
                              height: notchSize.height + activities.meterHeight)
            }
            if showsMeetingActivity {
                return CGSize(width: notchSize.width + 2 * IslandLayout.activityWing, height: notchSize.height)
            }
            if showsMusicActivity {
                return CGSize(width: notchSize.width + 2 * compactWing, height: notchSize.height)
            }
            return notchSize
        case .expanded:
            return expandedSize
        }
    }

    // MARK: - Voice notes

    /// The voice note asked to be shown: open the island (it stays pinned while the note runs).
    func presentVoice() {
        if state == .collapsed { expand() }
        onVoicePresent?()
    }

    func setVoiceHeight(_ height: CGFloat) {
        let height = height.rounded()
        guard height > 0, abs(height - voiceHeight) >= 1 else { return }
        if state == .expanded && voiceActive {
            Motion.perform(Motion.gentle) { voiceHeight = height }
        } else {
            voiceHeight = height
        }
    }

    private func setVoiceActive(_ active: Bool) {
        guard active != voiceActive else { return }
        Motion.perform(Motion.gentle) { voiceActive = active }
        // When the note ends, let the island go unless the pointer is still over it.
        if !active, state == .expanded, !expandedActiveZone().contains(NSEvent.mouseLocation) {
            collapse()
        }
    }

    var topRadius: CGFloat {
        switch state {
        case .collapsed: return collapsedTopRadius
        case .expanded: return IslandLayout.expandedTopRadius
        }
    }

    var bottomRadius: CGFloat {
        switch state {
        case .collapsed: return collapsedBottomRadius
        case .expanded: return IslandLayout.expandedBottomRadius
        }
    }

    func update(notchRect: CGRect) {
        self.notchRect = notchRect
        self.notchSize = CGSize(width: notchRect.width, height: notchRect.height)
    }

    func startTracking() {
        guard globalMonitor == nil, localMonitor == nil else { return }

        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMouse(at: NSEvent.mouseLocation)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleMouse(at: NSEvent.mouseLocation)
            }
            return event
        }
    }

    func stopTracking() {
        if let globalMonitor = globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor = localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        pendingExpand?.cancel()
        pendingExpand = nil
        pendingCollapse?.cancel()
        pendingCollapse = nil
    }

    private func handleMouse(at location: CGPoint) {
        switch state {
        case .collapsed:
            let hotZone = collapsedHotZone()
            // The low-battery notice stays put under the pointer, to be read or clicked, instead
            // of giving way to the open island.
            if activities.current?.kind.isNotice == true {
                cancelPendingExpand()
                activities.pointerMoved(inside: hotZone.contains(location))
                return
            }
            if hotZone.contains(location) {
                scheduleExpand(after: 0.06)
            } else {
                cancelPendingExpand()
            }
        case .expanded:
            // A voice note keeps the island open wherever the pointer goes.
            guard !voiceActive else {
                cancelPendingCollapse()
                return
            }
            let activeZone = expandedActiveZone()
            if activeZone.contains(location) {
                cancelPendingCollapse()
            } else {
                scheduleCollapse(after: 0.25)
            }
        }
    }

    private func collapsedHotZone() -> CGRect {
        let width = islandSize.width
        var zone = CGRect(
            x: notchRect.midX - width / 2,
            y: notchRect.maxY - islandSize.height,
            width: width,
            height: islandSize.height
        )
        zone = zone.insetBy(dx: -10, dy: -6)
        if zone.maxY < notchRect.maxY {
            zone.size.height += (notchRect.maxY - zone.maxY)
        }
        return zone
    }

    private func expandedActiveZone() -> CGRect {
        let rect = CGRect(
            x: notchRect.midX - expandedSize.width / 2,
            y: notchRect.maxY - expandedSize.height,
            width: expandedSize.width,
            height: expandedSize.height
        )
        return rect.insetBy(dx: -14, dy: -14)
    }

    private func scheduleExpand(after delay: TimeInterval) {
        if pendingExpand != nil { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state == .collapsed else { return }
                self.pendingExpand = nil
                self.expand()
            }
        }
        pendingExpand = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        if pendingCollapse != nil { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state == .expanded else { return }
                self.pendingCollapse = nil
                self.collapse()
            }
        }
        pendingCollapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingExpand() {
        pendingExpand?.cancel()
        pendingExpand = nil
    }

    private func cancelPendingCollapse() {
        pendingCollapse?.cancel()
        pendingCollapse = nil
    }

    private func scheduleHide(after delay: TimeInterval) {
        cancelPendingHide()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Only hide if still paused (no track or not playing).
                guard !self.nowPlaying.isPlaying else { return }
                self.hideActivityWork = nil
                Motion.perform(Motion.islandShrink) {
                    self.showsMusicActivity = false
                }
            }
        }
        hideActivityWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingHide() {
        hideActivityWork?.cancel()
        hideActivityWork = nil
    }

    var expandedSize: CGSize {
        if voiceActive {
            return CGSize(width: IslandLayout.voiceWidth, height: notchSize.height + voiceHeight)
        }
        return CGSize(width: max(IslandLayout.expandedWidth, notchSize.width + 2 * IslandLayout.minimumExpandedWing),
               height: notchSize.height + IslandLayout.contentTopPadding + expandedContentHeight
                   + IslandLayout.contentBottomPadding)
    }

    /// Pages with something to show, in tab order. Never empty: with nothing at all, the
    /// player page says "Nothing playing".
    var availablePages: [ExpandedPage] {
        var pages: [ExpandedPage] = []
        if nowPlaying.track != nil { pages.append(.player) }
        if calendarAvailable { pages.append(.calendar) }
        if linear.isConnected { pages.append(.tasks) }
        if settings.showSystemPage { pages.append(.system) }
        return pages.isEmpty ? [.player] : pages
    }

    /// The page actually on screen: the chosen one if it still has content, else the first.
    var visiblePage: ExpandedPage {
        let pages = availablePages
        return pages.contains(page) ? page : pages[0]
    }

    /// Tabs only appear when there is a real choice.
    var showsPageTabs: Bool {
        availablePages.count > 1
    }

    /// Where the island opens: a meeting about to start wins, then what is playing, then
    /// deadlines, then the calendar.
    private var preferredPage: ExpandedPage {
        let pages = availablePages
        if calendar.imminentMeeting != nil, pages.contains(.calendar) { return .calendar }
        if pages.contains(.player) { return .player }
        if pages.contains(.tasks), !linear.issues.isEmpty { return .tasks }
        return pages[0]
    }

    private var contentHeightForCurrentState: CGFloat {
        switch visiblePage {
        case .player:
            return nowPlaying.track != nil ? IslandLayout.playerHeight : IslandLayout.messageHeight
        case .calendar:
            return calendar.access == .granted
                ? IslandLayout.calendarHeight(events: calendar.events.count)
                : IslandLayout.messageHeight
        case .tasks:
            if case .failed = linear.status { return IslandLayout.messageHeight }
            let groups = TaskGroup.make(from: linear.issues,
                                        rowBudget: tasksExpanded ? .max : IslandLayout.compactTaskRows)
            let height = TaskGroup.height(of: groups)
            return tasksExpanded ? min(height, IslandLayout.expandedTasksMaxHeight) : height
        case .system:
            return IslandLayout.systemPageHeight(hasBattery: system.battery != nil)
        }
    }

    /// Re-derives the page height. While expanded the island resizes on the gentle spring
    /// (layout, no overshoot) as the content morphs — the sanctioned "height springs while the
    /// sub-views trade places" pairing.
    private func updateContentHeight(animated: Bool) {
        let height = contentHeightForCurrentState
        guard height != expandedContentHeight else { return }
        if animated && state == .expanded {
            Motion.perform(Motion.gentle) { expandedContentHeight = height }
        } else {
            expandedContentHeight = height
        }
    }

    /// The calendar page exists unless the user turned it off or denied calendar access.
    var calendarAvailable: Bool {
        settings.showCalendar && calendar.access != .denied
    }

    func show(_ page: ExpandedPage) {
        guard page != visiblePage, availablePages.contains(page) else { return }
        Motion.perform(Motion.snappy) {
            self.page = page
        }
    }

    /// "View more" on the tasks page: the list grows in place while the island stays open.
    func showMoreTasks() {
        guard !tasksExpanded else { return }
        tasksExpanded = true
        updateContentHeight(animated: true)
    }

    func openSettings() {
        collapse()
        onOpenSettings?()
    }

    func requestLowPowerMode() {
        onRequestLowPowerMode?()
    }

    /// The 🎙 button in the notch row.
    func toggleVoice() {
        voice.toggle()
    }

    func expand() {
        guard state != .expanded else { return }
        page = preferredPage
        linear.refresh()
        system.start()
        updateContentHeight(animated: false)
        cancelPendingExpand()
        Motion.perform(Motion.islandGrow) {
            state = .expanded
        }
        if settings.hapticFeedback {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        onStateChange?(.expanded)
    }

    func collapse() {
        guard state != .collapsed else { return }
        cancelPendingCollapse()
        Motion.perform(Motion.islandShrink) {
            state = .collapsed
        }
        tasksExpanded = false
        system.stop()
        onStateChange?(.collapsed)
    }
}
