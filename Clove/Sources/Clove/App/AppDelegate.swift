import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: NotchWindowController?
    private let settings = AppSettings()
    private let linear = LinearService()
    private let calendar = CalendarService()
    private lazy var settingsWindowController = SettingsWindowController(settings: settings, linear: linear,
                                                                         calendar: calendar)
    private var statusItem: NSStatusItem?
    private var voiceItem: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()

        let controller = NotchWindowController(settings: settings, linear: linear, calendar: calendar) { [weak self] in
            self?.showSettings()
        }
        windowController = controller
        controller.showWindow(nil)

        buildStatusItem()

        // The voice-note shortcut works from anywhere while Clove runs, once Linear is connected.
        let shortcuts = VoiceShortcutManager.shared
        shortcuts.onPress = { [weak controller] in controller?.model.voice.toggle() }
        linear.$status
            .map { $0 == .connected }
            .removeDuplicates()
            .sink { [weak self] connected in
                shortcuts.isEnabled = connected
                self?.voiceItem?.isHidden = !connected
            }
            .store(in: &cancellables)

        // With no Dock icon, and the menu bar item easily hidden behind the notch, the first
        // launch opens Settings so it is clear Clove is running and where to find it.
        if !UserDefaults.standard.bool(forKey: Self.launchedBeforeKey) {
            UserDefaults.standard.set(true, forKey: Self.launchedBeforeKey)
            showSettings()
        }

        #if DEBUG
        // Debug builds only: plays a scripted voice note through the island, no mic or Linear.
        if CommandLine.arguments.contains("--voice-demo") {
            Task { await controller.model.voice.runDemo() }
        }
        #endif

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.windowController?.reposition()
            }
            .store(in: &cancellables)
    }

    /// `clove://settings` opens the settings window (e.g. `open clove://settings` in Terminal).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "clove" {
            switch url.host {
            case "settings": showSettings()
            #if DEBUG
            // Debug builds only: `open clove://preview/low-battery` (or `/charging`) shows that
            // activity now, without draining the battery or unplugging.
            case "preview": windowController?.preview(url.lastPathComponent)
            #endif
            default: break
            }
        }
    }

    private static let launchedBeforeKey = "launchedBefore"

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.model.stopTracking()
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            let image = NSImage(systemSymbolName: "capsule.portrait.fill", accessibilityDescription: "Clove")
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()

        let aboutItem = NSMenuItem(
            title: "About Clove",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let voiceItem = NSMenuItem(
            title: "Record Voice Note",
            action: #selector(recordVoiceNote),
            keyEquivalent: ""
        )
        voiceItem.target = self
        voiceItem.isHidden = true
        menu.addItem(voiceItem)
        self.voiceItem = voiceItem

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Clove",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    /// Clove shows no menu bar of its own, but text fields still take their key equivalents from
    /// the main menu: ⌘V to paste a Linear key, ⌘Z while renaming a task, ⌘W to close Settings.
    /// No Quit here: a voice note can hold the keyboard while another app is in front, and ⌘Q
    /// meant for that app must not quit Clove.
    private func buildMainMenu() {
        let main = NSMenu()
        main.addItem(NSMenuItem())  // the application menu, never shown

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem()
        windowItem.submenu = window
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    @objc private func recordVoiceNote() {
        windowController?.model.voice.toggle()
    }

    @objc private func showSettings() {
        settingsWindowController.show()
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
