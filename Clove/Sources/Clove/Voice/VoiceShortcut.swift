import Carbon.HIToolbox
import Foundation

/// Preset global shortcuts for starting and finishing a voice note.
enum VoiceShortcut: String, CaseIterable, Identifiable {
    case optionSpace
    case controlOptionCommandV
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optionSpace: "⌥ Space"
        case .controlOptionCommandV: "⌃⌥⌘ V"
        case .off: "Off"
        }
    }

    fileprivate var keyCode: UInt32? {
        switch self {
        case .optionSpace: UInt32(kVK_Space)
        case .controlOptionCommandV: UInt32(kVK_ANSI_V)
        case .off: nil
        }
    }

    fileprivate var modifiers: UInt32 {
        switch self {
        case .optionSpace: UInt32(optionKey)
        case .controlOptionCommandV: UInt32(controlKey | optionKey | cmdKey)
        case .off: 0
        }
    }
}

/// Owns the registered global shortcut. Works while the app is running (it lives in the menu bar).
@MainActor
final class VoiceShortcutManager: ObservableObject {
    static let shared = VoiceShortcutManager()

    @Published var shortcut: VoiceShortcut {
        didSet {
            UserDefaults.standard.set(shortcut.rawValue, forKey: Self.defaultsKey)
            register()
        }
    }

    /// True when another app already owns the chosen shortcut.
    @Published private(set) var isTaken = false

    /// Called on the main thread when the shortcut is pressed.
    var onPress: (() -> Void)?

    /// The shortcut is held only while a voice note can do something (Linear is connected), so a
    /// fresh install does not take ⌥ Space from every other app.
    var isEnabled = false {
        didSet { if isEnabled != oldValue { register() } }
    }

    private static let defaultsKey = "voiceShortcut"
    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false
    /// While another app holds the shortcut, try again every few seconds, so it is picked up as
    /// soon as that app lets go.
    private var retryTimer: Timer?

    private init() {
        shortcut = UserDefaults.standard.string(forKey: Self.defaultsKey).flatMap(VoiceShortcut.init(rawValue:)) ?? .optionSpace
    }

    func register() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        isTaken = false
        guard isEnabled, let keyCode = shortcut.keyCode else { return }

        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x43_4C_56_56), id: 1)  // 'CLVV'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
            retryTimer?.invalidate()
            retryTimer = nil
        } else {
            isTaken = true
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isTaken, self.isEnabled, self.shortcut != .off else {
                    self?.retryTimer?.invalidate()
                    self?.retryTimer = nil
                    return
                }
                self.register()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { VoiceShortcutManager.shared.onPress?() }
            }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
