import AppKit
import ApplicationServices
import Combine
import CoreAudio
import os

/// Takes over the volume and mute keys — and, in the direct-download build, the brightness
/// keys — so macOS does not show its own indicators next to Clove's. Key presses are consumed
/// and the change is made by Clove instead (Core Audio for volume, DisplayServices for
/// brightness), in the same 1/16 steps as macOS (Option-Shift for 1/64 steps).
///
/// Requires Input Monitoring and event posting (both under Privacy & Security), which only the
/// user can grant in System Settings.
/// It is requested once, in context: the first time the volume changes while it is missing.
@MainActor
final class VolumeKeyInterceptor {
    private let settings: AppSettings
    private let center: ActivityCenter
    private let tap: VolumeKeyTap
    private var trustPoll: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// Set once Clove has shown the permission prompt, so it is never shown unprompted again.
    // Renamed when Input Monitoring was added to the request, so users asked only for event
    // posting before are asked once more.
    private static let askedKey = "askedForInputMonitoring"

    init(settings: AppSettings, center: ActivityCenter) {
        self.settings = settings
        self.center = center
        // Called on the key queue after a key changed the level.
        tap = VolumeKeyTap(
            onVolume: { [weak center] level, muted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { center?.post(.volume(level: level, muted: muted)) }
                }
            },
            onBrightness: { [weak center] level in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { center?.post(.brightness(level: level)) }
                }
            }
        )

        // At launch: start if already allowed, otherwise wait quietly for the permission.
        apply(enabled: settings.hideSystemVolumeHUD, userTurnedOn: false)
        settings.$hideSystemVolumeHUD
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in self?.apply(enabled: enabled, userTurnedOn: enabled) }
            .store(in: &cancellables)

        // The contextual moment to ask: the volume just changed and macOS showed its own indicator.
        center.$current
            .sink { [weak self] activity in
                guard let self, case .volume = activity?.kind else { return }
                self.askOnceIfNeeded()
            }
            .store(in: &cancellables)

        // Keys whose activity is turned off stay with macOS.
        settings.$showVolumeActivity
            .sink { [weak self] shown in self?.tap.takesVolume = shown }
            .store(in: &cancellables)
        settings.$showBrightnessActivity
            .sink { [weak self] shown in self?.tap.takesBrightness = shown }
            .store(in: &cancellables)

        // The tap only swallows keys for outputs whose volume Clove can set itself.
        tap.outputSettable = Self.defaultOutputIsSettable()
        var address = AudioHardware.defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(AudioHardware.systemObject, &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.tap.outputSettable = Self.defaultOutputIsSettable() }
        }
    }

    private static func defaultOutputIsSettable() -> Bool {
        AudioHardware.defaultOutputDevice().map(AudioHardware.canSetVolume(of:)) ?? false
    }

    private func apply(enabled: Bool, userTurnedOn: Bool) {
        guard enabled else {
            tap.stop()
            stopTrustPoll()
            return
        }
        if settings.refreshAccessibility() {
            tap.start()
        } else if tap.start(quiet: true) {
            // Granted after all: the preflight answer can lag behind System Settings.
            settings.noteEventAccessGranted()
        } else {
            if userTurnedOn {
                settings.requestAccessibility()
                UserDefaults.standard.set(true, forKey: Self.askedKey)
            }
            startTrustPoll()
        }
    }

    private func askOnceIfNeeded() {
        guard settings.hideSystemVolumeHUD,
              !settings.accessibilityGranted,
              !UserDefaults.standard.bool(forKey: Self.askedKey)
        else { return }
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        settings.requestAccessibility()
    }

    /// The permission is granted in System Settings while Clove runs; poll until it is.
    ///
    /// macOS answers the preflight check once per process, so after the user grants access it
    /// keeps saying no until Clove restarts. Creating the tap is checked live, so the poll simply
    /// tries that: the first success is the grant.
    private func startTrustPoll() {
        guard trustPoll == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.tap.start(quiet: true) else { return }
                self.settings.noteEventAccessGranted()
                self.stopTrustPoll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustPoll = timer
    }

    private func stopTrustPoll() {
        trustPoll?.invalidate()
        trustPoll = nil
    }
}

/// The event tap itself, on a thread of its own.
///
/// macOS disables an event tap whose callback is slow, and every key pressed while it is
/// disabled reaches the system — which then shows its indicator. So the tap never runs on the
/// main thread (busy drawing, decoding artwork, reading the calendar), its callback only
/// decides and returns, and the Core Audio work happens afterwards on `volumeQueue`.
final class VolumeKeyTap: @unchecked Sendable {
    private enum Key { case volumeUp, volumeDown, mute, brightnessUp, brightnessDown }

    // NX_KEYTYPE_* from IOKit/hidsystem/ev_keymap.h and NX_SUBTYPE_AUX_CONTROL_BUTTONS.
    private static let soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    private static let auxControlButtons: Int16 = 8

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.clove.Clove", category: "VolumeKeys")
    private let keyQueue = DispatchQueue(label: "app.clove.level-keys", qos: .userInteractive)
    /// Report the new level after a key press, on `keyQueue`.
    private let onVolume: (Float32, Bool) -> Void
    private let onBrightness: (Float) -> Void

    private let lock = NSLock()
    private var machPort: CFMachPort?
    private var runLoop: CFRunLoop?
    private var _outputSettable = false
    private var _takesVolume = true
    private var _takesBrightness = true

    /// Whether the current default output's volume can be set; if not, keys go to macOS.
    var outputSettable: Bool {
        get { lock.withLock { _outputSettable } }
        set { lock.withLock { _outputSettable = newValue } }
    }

    /// Whether Clove shows its own volume or brightness activity; keys it would show nothing
    /// for go to macOS, so a press always shows an indicator.
    var takesVolume: Bool {
        get { lock.withLock { _takesVolume } }
        set { lock.withLock { _takesVolume = newValue } }
    }

    var takesBrightness: Bool {
        get { lock.withLock { _takesBrightness } }
        set { lock.withLock { _takesBrightness = newValue } }
    }

    init(onVolume: @escaping (Float32, Bool) -> Void, onBrightness: @escaping (Float) -> Void) {
        self.onVolume = onVolume
        self.onBrightness = onBrightness
    }

    /// Creates and starts the tap; true if it is running. `quiet` skips the failure log, for
    /// the permission poll, where failing is the expected answer.
    @discardableResult
    func start(quiet: Bool = false) -> Bool {
        guard lock.withLock({ machPort == nil }) else { return true }

        let mask = CGEventMask(1) << CGEventMask(NSEvent.EventType.systemDefined.rawValue)
        // C callback: cannot capture, so `self` travels through `userInfo`.
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<VolumeKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
            return tap.handle(type: type, event: event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            if !quiet {
                log.error("Could not create the volume key event tap")
            }
            return false
        }
        lock.withLock { machPort = port }

        let thread = Thread { [weak self] in
            guard let self else { return }
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            let current = CFRunLoopGetCurrent()
            CFRunLoopAddSource(current, source, .commonModes)
            self.lock.withLock { self.runLoop = current }
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "app.clove.volume-keys"
        thread.qualityOfService = .userInteractive
        thread.start()
        log.info("Volume key tap started")
        return true
    }

    func stop() {
        let (port, loop) = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            defer { machPort = nil; runLoop = nil }
            return (machPort, runLoop)
        }
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let loop { CFRunLoopStop(loop) }
        log.info("Volume key tap stopped")
    }

    /// Runs on the tap thread. Decide and return; never block here.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log.error("Volume key tap was disabled (\(type.rawValue, privacy: .public)); re-enabling")
            if let port = lock.withLock({ machPort }) {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.type == .systemDefined,
              nsEvent.subtype.rawValue == Self.auxControlButtons
        else { return Unmanaged.passUnretained(event) }

        let key: Key
        switch (nsEvent.data1 & 0xFFFF_0000) >> 16 {
        case Self.soundUp: key = .volumeUp
        case Self.soundDown: key = .volumeDown
        case Self.mute: key = .mute
        #if DIRECT
        case Self.brightnessUp: key = .brightnessUp
        case Self.brightnessDown: key = .brightnessDown
        #endif
        default: return Unmanaged.passUnretained(event)  // media keys, and brightness in the App Store build
        }

        switch key {
        case .volumeUp, .volumeDown, .mute:
            // Outputs without software volume (some HDMI/USB devices) stay with macOS.
            guard outputSettable, takesVolume else { return Unmanaged.passUnretained(event) }
        case .brightnessUp, .brightnessDown:
            #if DIRECT
            // External displays and a closed lid stay with macOS.
            guard takesBrightness, BrightnessControl.builtInDisplay != nil else { return Unmanaged.passUnretained(event) }
            #else
            return Unmanaged.passUnretained(event)
            #endif
        }

        let isKeyDown = (nsEvent.data1 & 0xFF00) >> 8 == 0xA
        if isKeyDown {
            let fine = event.flags.contains(.maskAlternate) && event.flags.contains(.maskShift)
            keyQueue.async { [weak self] in self?.change(key, fine: fine) }
        }
        return nil  // consume both key down and key up: macOS sees nothing and shows nothing
    }

    /// Runs on `keyQueue`.
    private func change(_ key: Key, fine: Bool) {
        let step: Float32 = fine ? 1.0 / 64 : 1.0 / 16
        switch key {
        case .volumeUp, .volumeDown, .mute:
            changeVolume(key, step: step)
        case .brightnessUp, .brightnessDown:
            #if DIRECT
            changeBrightness(up: key == .brightnessUp, step: step)
            #endif
        }
    }

    private func changeVolume(_ key: Key, step: Float32) {
        guard let device = AudioHardware.defaultOutputDevice() else { return }
        let current = AudioHardware.volume(of: device) ?? 0
        let muted = AudioHardware.isMuted(device)
        switch key {
        case .mute:
            AudioHardware.setMuted(!muted, of: device)
        case .volumeUp:
            if muted { AudioHardware.setMuted(false, of: device) }
            AudioHardware.setVolume(Self.stepped(current, by: step), of: device)
        case .volumeDown:
            AudioHardware.setVolume(Self.stepped(current, by: -step), of: device)
        case .brightnessUp, .brightnessDown:
            return
        }
        // Report even at the limits, where the volume (and so AudioMonitor) does not change.
        onVolume(AudioHardware.volume(of: device) ?? current, AudioHardware.isMuted(device))
    }

    #if DIRECT
    private func changeBrightness(up: Bool, step: Float) {
        guard let display = BrightnessControl.builtInDisplay,
              let current = BrightnessControl.brightness(of: display)
        else { return }
        BrightnessControl.setBrightness(Self.stepped(current, by: up ? step : -step), of: display)
        onBrightness(BrightnessControl.brightness(of: display) ?? current)
    }
    #endif

    /// Moves `value` to the next step boundary, as macOS does (so 0.53 + 1/16 lands on 0.5625).
    private static func stepped(_ value: Float, by step: Float) -> Float {
        let next = ((value / abs(step)).rounded() + (step > 0 ? 1 : -1)) * abs(step)
        return min(1, max(0, next))
    }
}
