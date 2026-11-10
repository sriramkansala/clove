import AppKit
import os

/// Runs AppleScript off the main thread.
///
/// Sending an Apple Event blocks until the target app replies — and, the first time, until the
/// user answers the "Clove wants to control …" permission prompt — so scripts must never run on
/// the main thread, or the whole app freezes while the prompt is up. `NSAppleScript` is not
/// thread-safe, so every script is compiled and executed on one private serial queue.
enum AppleScriptRunner {
    struct Outcome {
        let descriptor: NSAppleEventDescriptor?
        /// AppleScript error number, e.g. -1743 when the user denied automation permission.
        let errorNumber: Int?
    }

    private static let queue = DispatchQueue(label: "app.clove.applescript", qos: .userInitiated)
    /// Compiled scripts by source. Only touched on `queue`.
    nonisolated(unsafe) private static var cache: [String: NSAppleScript] = [:]
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.clove.Clove", category: "AppleScript")

    /// Runs `source` on the script queue; `completion`, if given, receives the outcome on the main actor.
    static func run(_ source: String, completion: (@MainActor (Outcome) -> Void)? = nil) {
        queue.async {
            let outcome = execute(source)
            guard let completion else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(outcome) }
            }
        }
    }

    private static func execute(_ source: String) -> Outcome {
        let script: NSAppleScript
        if let cached = cache[source] {
            script = cached
        } else {
            guard let compiled = NSAppleScript(source: source) else {
                return Outcome(descriptor: nil, errorNumber: nil)
            }
            cache[source] = compiled
            script = compiled
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown error"
            log.error("AppleScript error \(number ?? 0, privacy: .public): \(message, privacy: .public)")
            return Outcome(descriptor: nil, errorNumber: number)
        }
        return Outcome(descriptor: result, errorNumber: nil)
    }
}
