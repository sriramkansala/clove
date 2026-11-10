import AppKit

@main
enum CloveApp {
    private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}
