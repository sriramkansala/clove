import AppKit
import CoreGraphics
import ServiceManagement

/// User preferences, persisted in UserDefaults. Launch at login is read from and written to
/// `SMAppService.mainApp` directly, so it always reflects System Settings > Login Items.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var showMusicActivity: Bool { didSet { save(showMusicActivity, "showMusicActivity") } }
    @Published var showChargingActivity: Bool { didSet { save(showChargingActivity, "showChargingActivity") } }
    @Published var showDeviceActivity: Bool { didSet { save(showDeviceActivity, "showDeviceActivity") } }
    @Published var showVolumeActivity: Bool { didSet { save(showVolumeActivity, "showVolumeActivity") } }
    /// Direct-download build only; the App Store build cannot change brightness.
    @Published var showBrightnessActivity: Bool { didSet { save(showBrightnessActivity, "showBrightnessActivity") } }
    /// "Meeting in 10 min" beside the notch before a calendar event with a video link.
    @Published var showMeetingReminders: Bool { didSet { save(showMeetingReminders, "showMeetingReminders") } }
    /// A short notice when a Linear issue is due today or overdue.
    @Published var showTaskReminders: Bool { didSet { save(showTaskReminders, "showTaskReminders") } }
    @Published var showCalendar: Bool { didSet { save(showCalendar, "showCalendar") } }
    @Published var showSystemPage: Bool { didSet { save(showSystemPage, "showSystemPage") } }
    @Published var hapticFeedback: Bool { didSet { save(hapticFeedback, "hapticFeedback") } }
    /// Take over the volume keys so macOS hides its own volume indicator (needs Input Monitoring
    /// and Accessibility).
    @Published var hideSystemVolumeHUD: Bool { didSet { save(hideSystemVolumeHUD, "hideSystemVolumeHUD") } }
    /// Whether Clove may filter keyboard events — Input Monitoring and Accessibility in System
    /// Settings.
    @Published private(set) var accessibilityGranted = CGPreflightPostEventAccess()

    @Published private(set) var launchAtLogin: Bool
    /// The login item is registered but waits for the user to allow it in System Settings.
    @Published private(set) var launchAtLoginNeedsApproval = false
    /// Set when registering or unregistering the login item fails; shown under the toggle.
    @Published private(set) var launchAtLoginError: String?

    init() {
        defaults.register(defaults: [
            "showMusicActivity": true,
            "showChargingActivity": true,
            "showDeviceActivity": true,
            "showVolumeActivity": true,
            "showBrightnessActivity": true,
            "showMeetingReminders": true,
            "showTaskReminders": true,
            "showCalendar": true,
            "showSystemPage": true,
            "hapticFeedback": true,
            "hideSystemVolumeHUD": true,
        ])
        showMusicActivity = defaults.bool(forKey: "showMusicActivity")
        showChargingActivity = defaults.bool(forKey: "showChargingActivity")
        showDeviceActivity = defaults.bool(forKey: "showDeviceActivity")
        showVolumeActivity = defaults.bool(forKey: "showVolumeActivity")
        showBrightnessActivity = defaults.bool(forKey: "showBrightnessActivity")
        showMeetingReminders = defaults.bool(forKey: "showMeetingReminders")
        showTaskReminders = defaults.bool(forKey: "showTaskReminders")
        showCalendar = defaults.bool(forKey: "showCalendar")
        showSystemPage = defaults.bool(forKey: "showSystemPage")
        hapticFeedback = defaults.bool(forKey: "hapticFeedback")
        hideSystemVolumeHUD = defaults.bool(forKey: "hideSystemVolumeHUD")
        launchAtLogin = false
        readLaunchAtLogin()
    }

    /// Whether an activity of this kind should be shown at all.
    func allows(_ kind: ActivityKind) -> Bool {
        switch kind {
        case .charging, .lowBattery: return showChargingActivity
        case .audioDevice: return showDeviceActivity
        case .volume: return showVolumeActivity
        case .brightness: return showBrightnessActivity
        case .taskDue: return showTaskReminders
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        // Re-read rather than trusting `enabled`: the user may need to approve it in System Settings.
        readLaunchAtLogin()
    }

    /// Call when the settings window opens, in case the login item was changed in System Settings.
    func reloadLaunchAtLogin() {
        readLaunchAtLogin()
        refreshAccessibility()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func readLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        launchAtLoginNeedsApproval = status == .requiresApproval
    }

    /// Re-reads whether Clove may filter keyboard events and returns it.
    ///
    /// This is the event-access check, not `AXIsProcessTrusted()`: the AX API (controlling other
    /// apps) is unavailable to sandboxed apps and always reports false, while event access is
    /// the permission an active event tap needs and works under the App Sandbox.
    @discardableResult
    func refreshAccessibility() -> Bool {
        // Once the tap exists, access is proven; the preflight answer is fixed for the life of
        // the process and would keep reporting the state at launch.
        // A filtering key tap needs both Input Monitoring (macOS checks it first when the tap is
        // created) and event posting; both are listed under Privacy & Security.
        let granted = accessibilityGranted || (CGPreflightListenEventAccess() && CGPreflightPostEventAccess())
        if granted != accessibilityGranted {
            accessibilityGranted = granted
        }
        return granted
    }

    /// Called when an event tap was created: access is granted even if the preflight check,
    /// answered once at launch, still says otherwise.
    func noteEventAccessGranted() {
        if !accessibilityGranted {
            accessibilityGranted = true
        }
    }

    /// Shows the system prompts that add Clove to Input Monitoring and Accessibility.
    func requestAccessibility() {
        // Each call shows its own system prompt the first time; Input Monitoring is the one the
        // tap is refused without.
        CGRequestListenEventAccess()
        CGRequestPostEventAccess()
    }

    /// Opens the Privacy & Security list Clove is still missing from: Input Monitoring first (the
    /// key tap is refused without it), then Accessibility.
    func openKeyAccessSettings() {
        let pane = CGPreflightListenEventAccess() ? "Privacy_Accessibility" : "Privacy_ListenEvent"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func save(_ value: Bool, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
