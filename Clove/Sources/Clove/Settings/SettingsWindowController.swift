import AppKit
import SwiftUI

/// The settings window. Clove is an agent app with no Dock icon, so the app is activated
/// explicitly to bring the window in front of other apps.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let settings: AppSettings

    init(settings: AppSettings, linear: LinearService, calendar: CalendarService) {
        self.settings = settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clove Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(settings: settings, linear: linear, calendar: calendar))
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        settings.reloadLaunchAtLogin()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // macOS may decline the activation request when Clove is opened from the background
        // (e.g. `open clove://settings`), which would leave the window ordered out.
        window?.orderFrontRegardless()
    }
}
