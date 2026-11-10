import Foundation
import SwiftUI

enum ActivityKind: Equatable {
    case charging(level: Int)          // just plugged in
    case lowBattery(level: Int, lowPowerMode: LowPowerMode)  // crossed 20 % or 10 % while on battery
    case audioDevice(name: String)     // default output switched to a Bluetooth device
    case volume(level: Float, muted: Bool)  // output volume changed; level is 0...1
    case brightness(level: Float)           // display brightness changed (direct build only)
    case taskDue(title: String, overdue: Bool)  // a Linear issue is due today or overdue
}

/// Where Low Power Mode stands for the low-battery notice.
enum LowPowerMode: Equatable {
    /// Off: the notice offers it.
    case off
    /// The notice was clicked and the direct build's helper needs allowing in Login Items first
    /// (once); the notice waits for it.
    case approving
    /// The notice was clicked and Battery settings are opening; the notice waits for it there.
    case requested
    /// On: the notice is gold.
    case on
}

extension ActivityKind {
    /// The low-battery notice: a card below the camera that the pointer can rest on (it stays
    /// put instead of opening the island) and, while it offers Low Power Mode, click.
    var isNotice: Bool {
        if case .lowBattery = self { return true }
        return false
    }

    var isClickable: Bool {
        if case .lowBattery(_, .off) = self { return true }
        return false
    }

    /// Levels the user is adjusting right now (volume, brightness): shown at once, updated in place.
    var isLiveLevel: Bool {
        switch self {
        case .volume, .brightness: return true
        case .charging, .lowBattery, .audioDevice, .taskDue: return false
        }
    }

    func isSameLiveLevel(as other: ActivityKind) -> Bool {
        switch (self, other) {
        case (.volume, .volume), (.brightness, .brightness): return true
        default: return false
        }
    }
}

struct TransientActivity: Identifiable, Equatable {
    var id = UUID()
    let kind: ActivityKind
}

/// Queues short "live activities" that are shown beside the notch for a few seconds,
/// one at a time, while the island is collapsed.
@MainActor
final class ActivityCenter: ObservableObject {
    @Published private(set) var current: TransientActivity?
    /// Settings filter; activities it rejects are dropped.
    var isAllowed: (ActivityKind) -> Bool = { _ in true }

    private var queue: [ActivityKind] = []
    private var pendingWork: DispatchWorkItem?
    private let displayDuration: TimeInterval = 3
    private let levelDisplayDuration: TimeInterval = 1.5
    /// The low-battery notice gives the user time to reach it, and to finish in System Settings.
    private let noticeDuration: TimeInterval = 6
    private let lowPowerWait: TimeInterval = 30
    /// How long a notice stays once the pointer leaves it.
    private let noticeLinger: TimeInterval = 2
    private let maxQueued = 3
    private var pointerInside = false

    /// Width of each wing beside the notch for the activity being shown.
    var wingWidth: CGFloat {
        switch current?.kind {
        case .lowBattery: return IslandLayout.noticeWing
        case .charging, .volume, .brightness: return 76
        case .audioDevice, .taskDue: return 110
        case nil: return 0
        }
    }

    /// Extra height below the notch for the level meter drawn along the island's bottom edge, for
    /// the charging moment, or for the low-battery notice.
    var meterHeight: CGFloat {
        switch current?.kind {
        case .charging: return 34
        case .lowBattery: return IslandLayout.noticeStageHeight
        case .volume, .brightness: return 8
        case .audioDevice, .taskDue, nil: return 0
        }
    }

    func post(_ kind: ActivityKind) {
        guard isAllowed(kind) else { return }
        if kind.isLiveLevel {
            showLevel(kind)
            return
        }
        guard current?.kind != kind, !queue.contains(kind), queue.count < maxQueued else { return }
        queue.append(kind)
        // While an activity is showing (or in the gap after one), the timer chain picks this up.
        if current == nil && pendingWork == nil {
            showNext()
        }
    }

    private func showNext() {
        guard !queue.isEmpty else { return }
        let next = TransientActivity(kind: queue.removeFirst())
        pointerInside = false
        Motion.perform(next.kind.isNotice ? Motion.notice : Motion.islandGrow) {
            current = next
        }
        schedule(after: duration(of: next.kind)) { [weak self] in self?.hideCurrent() }
    }

    private func duration(of kind: ActivityKind) -> TimeInterval {
        switch kind {
        case .lowBattery(_, .off): return noticeDuration
        case .lowBattery(_, .approving), .lowBattery(_, .requested): return lowPowerWait
        default: return displayDuration
        }
    }

    /// The pointer moved, in or out of the island. A notice that can be clicked stays while the
    /// pointer is on it, and for a moment after it leaves.
    func pointerMoved(inside: Bool) {
        guard current?.kind.isClickable == true, inside != pointerInside else { return }
        pointerInside = inside
        if inside {
            pendingWork?.cancel()
            pendingWork = nil
        } else {
            schedule(after: noticeLinger) { [weak self] in self?.hideCurrent() }
        }
    }

    /// The low-battery notice was clicked and System Settings is opening (`mode` says for what):
    /// the notice waits for Low Power Mode to come on.
    func awaitLowPowerMode(_ mode: LowPowerMode) {
        guard let showing = current, case .lowBattery(let level, let shown) = showing.kind,
              shown != .on, shown != mode else { return }
        replace(showing, with: .lowBattery(level: level, lowPowerMode: mode))
        schedule(after: lowPowerWait) { [weak self] in self?.hideCurrent() }
    }

    /// Low Power Mode came on: a low-battery notice on screen turns gold, then leaves.
    func lowPowerModeTurnedOn() {
        guard let showing = current, case .lowBattery(let level, let mode) = showing.kind, mode != .on else { return }
        replace(showing, with: .lowBattery(level: level, lowPowerMode: .on))
        schedule(after: displayDuration) { [weak self] in self?.hideCurrent() }
    }

    /// Changes what the activity on screen says, in place (same id, so its view updates rather
    /// than leaving and arriving).
    private func replace(_ showing: TransientActivity, with kind: ActivityKind) {
        pointerInside = false
        Motion.perform(Motion.notice) {
            current = TransientActivity(id: showing.id, kind: kind)
        }
    }

    /// Volume and brightness changes are the user's own action, so they show immediately and
    /// update in place while keys are held, instead of queueing one notification per key press.
    /// An activity they interrupt is shown again afterwards.
    private func showLevel(_ kind: ActivityKind) {
        if let showing = current, showing.kind.isSameLiveLevel(as: kind) {
            current = TransientActivity(id: showing.id, kind: kind)  // same id: the view updates, no cross-fade
        } else {
            // Resume an interrupted notification afterwards; a stale level is not worth repeating.
            if let showing = current, !showing.kind.isLiveLevel {
                queue.insert(showing.kind, at: 0)
            }
            pointerInside = false
            Motion.perform(Motion.islandGrow) {
                current = TransientActivity(kind: kind)
            }
        }
        schedule(after: levelDisplayDuration) { [weak self] in self?.hideCurrent() }
    }

    /// A notice leaves as it came: blurring out while the island closes, on the same spring.
    private func hideCurrent() {
        pointerInside = false
        let notice = current?.kind.isNotice == true
        Motion.perform(notice ? Motion.notice : Motion.islandShrink) {
            current = nil
        }
        schedule(after: notice ? Motion.Duration.notice : Motion.islandShrinkSettle) { [weak self] in
            self?.showNext()
        }
    }

    private func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingWork = nil
                action()
            }
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
