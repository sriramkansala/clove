import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var linear: LinearService
    @ObservedObject var calendar: CalendarService

    private var versionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(
                        "Launch at login",
                        isOn: Binding(
                            get: { settings.launchAtLogin },
                            set: { settings.setLaunchAtLogin($0) }
                        )
                    )
                    if settings.launchAtLoginNeedsApproval {
                        PermissionHint(text: "Allow Clove in System Settings › General › Login Items",
                                       button: "Open Login Items", action: settings.openLoginItemsSettings)
                    }
                    if let error = settings.launchAtLoginError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Toggle("Haptic feedback", isOn: $settings.hapticFeedback)
            } header: {
                Text("General")
            } footer: {
                Text("Clove lives in the notch: move the pointer there to open it. These settings are also in the menu bar.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Live activities") {
                Toggle("Now playing", isOn: $settings.showMusicActivity)
                Captioned(caption: Self.lowBatteryNote) {
                    Toggle("Charging and low battery", isOn: $settings.showChargingActivity)
                }
                Toggle("Headphones and speakers", isOn: $settings.showDeviceActivity)
                Toggle("Meeting reminders", isOn: $settings.showMeetingReminders)
                Toggle("Linear deadlines", isOn: $settings.showTaskReminders)

                Captioned(caption: settings.hideSystemVolumeHUD ? nil : "Appears alongside the system volume indicator.") {
                    Toggle("Volume", isOn: $settings.showVolumeActivity)
                }

                #if DIRECT
                Captioned(caption: settings.hideSystemVolumeHUD ? nil : "Shown while Clove handles the brightness keys (below).") {
                    Toggle("Brightness", isOn: $settings.showBrightnessActivity)
                }
                #endif

                VStack(alignment: .leading, spacing: 2) {
                    Toggle(Self.takeoverTitle, isOn: $settings.hideSystemVolumeHUD)
                    Text(Self.takeoverNote)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if settings.hideSystemVolumeHUD && !settings.accessibilityGranted {
                        PermissionHint(text: "Allow Clove under Privacy & Security › Input Monitoring and Accessibility",
                                       button: "Open System Settings", action: settings.openKeyAccessSettings)
                    }
                }
            }

            Section("Expanded view") {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Upcoming events", isOn: $settings.showCalendar)
                    switch calendar.access {
                    case .notDetermined:
                        PermissionHint(text: "Clove needs access to your calendars",
                                       button: "Allow…", action: calendar.requestAccess)
                    case .denied:
                        PermissionHint(text: "Allow Clove under Privacy & Security › Calendars",
                                       button: "Open System Settings", action: Self.openCalendarSettings)
                    case .granted:
                        EmptyView()
                    }
                }
                Toggle("Battery and performance", isOn: $settings.showSystemPage)
            }

            LinearSettingsSection(linear: linear)

            VoiceSettingsSection(linear: linear)

            Section {
                Text("Clove \(versionString)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 560)
    }

    private static func openCalendarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}

private extension SettingsView {
    #if DIRECT
    static let takeoverTitle = "Hide macOS volume and brightness indicators"
    static let takeoverNote = "Clove handles the volume and brightness keys itself. Needs Input Monitoring and Accessibility permission."
    static let lowBatteryNote = "Clicking the low-battery notice turns on Low Power Mode, through a helper you allow once in Login Items."
    #else
    static let takeoverTitle = "Hide macOS volume indicator"
    static let takeoverNote = "Clove handles the volume keys itself. Needs Input Monitoring and Accessibility permission."
    static let lowBatteryNote = "Clicking the low-battery notice opens Battery settings, where you can turn on Low Power Mode."
    #endif
}

/// A control with an optional caption under it, in one row.
private struct Captioned<Content: View>: View {
    let caption: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            content
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// Something Clove is missing a permission for, and the button that fixes it.
private struct PermissionHint: View {
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.caption)
                .foregroundColor(.orange)
            Spacer()
            Button(button, action: action)
                .controlSize(.small)
        }
    }
}

/// Connect a Linear account with a personal API key. The key is checked with Linear before it
/// is kept, and is stored only in the keychain.
private struct LinearSettingsSection: View {
    @ObservedObject var linear: LinearService
    @State private var draftKey = ""

    var body: some View {
        Section {
            switch linear.status {
            case .connected:
                HStack {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Spacer()
                    Button("Disconnect") { linear.disconnect() }
                }
            case .connecting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking the key with Linear…")
                        .foregroundColor(.secondary)
                }
            case .notConnected, .failed:
                HStack {
                    SecureField("Personal API key", text: $draftKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(connect)
                    Button("Connect", action: connect)
                        .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if case .failed(let message) = linear.status {
                    HStack(spacing: 8) {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.red)
                        if linear.apiKey != nil {
                            Spacer()
                            Button("Disconnect") { linear.disconnect() }
                                .controlSize(.small)
                        }
                    }
                }
            }
        } header: {
            Text("Linear")
        } footer: {
            Text("Shows your issues in the current cycle (all your open issues if your team has no cycle running), and a reminder when one is due today or overdue. Create a key in Linear under Settings › Security & access › Personal API keys. It is stored in your keychain.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func connect() {
        linear.connect(apiKey: draftKey)
        draftKey = ""
    }
}

/// The voice-note shortcut. Notes are recorded, transcribed and understood on this Mac, then
/// reviewed in the island before anything is sent to Linear.
private struct VoiceSettingsSection: View {
    @ObservedObject var linear: LinearService
    @ObservedObject private var shortcuts = VoiceShortcutManager.shared

    var body: some View {
        Section {
            Picker("Shortcut", selection: $shortcuts.shortcut) {
                ForEach(VoiceShortcut.allCases) { shortcut in
                    Text(shortcut.title).tag(shortcut)
                }
            }
            if !linear.isConnected {
                Text("Connect Linear above to use voice notes.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let reason = VoicePlanner.unavailableReason {
                Text(reason)
                    .font(.caption)
                    .foregroundColor(.orange)
            } else if shortcuts.isTaken {
                Text("Another app already uses \(shortcuts.shortcut.title). Turn it off there or pick a different shortcut.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        } header: {
            Text("Voice notes")
        } footer: {
            Text("Press the shortcut or 🎙 in the island, say what changed, then press it again (or ⏎). Transcription and understanding run on this Mac with Apple Intelligence; you review every change in the island before it is sent to Linear. Needs a Linear key with write access.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
