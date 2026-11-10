import AppKit
import IOKit.ps

/// Posts a charging activity when the Mac is plugged in, and a low-battery notice when the level
/// crosses 20 % or 10 % on battery, which offers Low Power Mode and turns gold when it comes on.
/// Does nothing on Macs without a battery.
@MainActor
final class BatteryMonitor {
    private struct Reading: Equatable {
        var pluggedIn: Bool
        var level: Int
    }

    private let center: ActivityCenter
    private let lowThresholds = [20, 10]
    private var last: Reading?
    private var announcedThresholds: Set<Int> = []
    /// When the Mac was last plugged in, while it stays plugged in.
    private(set) var pluggedInAt: Date?
    // Touched from deinit to unregister; only ever mutated on the main actor.
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?
    nonisolated(unsafe) private var lowPowerObserver: NSObjectProtocol?

    /// Where Low Power Mode is switched on by hand. Only root can change it (`pmset`), so this is
    /// the App Store build's way, and the direct build's if its helper can't be used.
    private static let batterySettings = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!
    #if DIRECT
    private let lowPowerHelper = LowPowerModeHelper()
    #endif

    init(center: ActivityCenter) {
        self.center = center
        // The first reading is only a baseline; nothing is announced at launch.
        last = Self.read()
        guard last != nil else { return }

        // The callback is a C function pointer and cannot capture; route through `context`.
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.powerSourceChanged() }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }

        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lowPowerModeChanged() }
        }
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        if let lowPowerObserver {
            NotificationCenter.default.removeObserver(lowPowerObserver)
        }
    }

    /// The low-battery notice was clicked. The direct build switches Low Power Mode on through
    /// its helper (the first time, once the user allows the helper in Login Items) and the notice
    /// turns gold; the App Store build opens Battery settings, and the notice waits for it there.
    func requestLowPowerMode() {
        #if DIRECT
        lowPowerHelper.turnOn { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .on: center.lowPowerModeTurnedOn()
            case .awaitingApproval: center.awaitLowPowerMode(.approving)
            case .unavailable: openBatterySettings()
            }
        }
        #else
        openBatterySettings()
        #endif
    }

    private func openBatterySettings() {
        NSWorkspace.shared.open(Self.batterySettings)
        center.awaitLowPowerMode(.requested)
    }

    private func lowPowerModeChanged() {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            center.lowPowerModeTurnedOn()
        }
    }

    private func powerSourceChanged() {
        guard let now = Self.read(), let previous = last else { return }
        last = now
        if now.pluggedIn != previous.pluggedIn {
            pluggedInAt = now.pluggedIn ? Date() : nil
        }

        if now.pluggedIn {
            announcedThresholds.removeAll()
            if !previous.pluggedIn {
                center.post(.charging(level: now.level))
            }
            return
        }

        for threshold in lowThresholds
        where previous.level > threshold && now.level <= threshold && !announcedThresholds.contains(threshold) {
            announcedThresholds.insert(threshold)
            let lowPowerMode: LowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled ? .on : .off
            center.post(.lowBattery(level: now.level, lowPowerMode: lowPowerMode))
        }
    }

    /// Current state of the internal battery, or nil if there is none.
    private static func read() -> Reading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                    .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let pluggedIn = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return Reading(pluggedIn: pluggedIn, level: current * 100 / max)
        }
        return nil
    }
}
