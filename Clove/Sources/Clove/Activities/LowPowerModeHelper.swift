#if DIRECT
import Foundation
import ServiceManagement

/// Switches Low Power Mode on through Clove's helper, a launchd daemon that runs as root
/// (Clove/Helper; macOS lets only root change Low Power Mode).
///
/// The first time, macOS wants the user to allow the helper in Login Items: Clove opens Login
/// Items and switches Low Power Mode on as soon as it's allowed. After that a click is enough.
@MainActor
final class LowPowerModeHelper {
    enum Outcome {
        /// Low Power Mode is on.
        case on
        /// Login Items is open, waiting for the user to allow the helper.
        case awaitingApproval
        /// The helper can't be used (missing, refused, or not answering).
        case unavailable
    }

    private let service = SMAppService.daemon(plistName: LowPowerModeHelperID.plistName)
    private var approvalTimer: Timer?
    /// How long to watch for the helper being allowed. Longer than the notice waits: allowing
    /// takes finding Clove in a list and a password, and the click asked for Low Power Mode
    /// whether or not the notice is still up.
    private let approvalWait: TimeInterval = 120

    /// Turns Low Power Mode on. `report` gets `.awaitingApproval` first if the helper still needs
    /// allowing, then the result.
    func turnOn(_ report: @escaping @MainActor (Outcome) -> Void) {
        approvalTimer?.invalidate()
        // A daemon that was never registered reports `.notFound` (no record yet), not
        // `.notRegistered`. Registering throws when macOS wants the user's approval first; the
        // status says so too.
        if service.status == .notRegistered || service.status == .notFound {
            try? service.register()
        }
        switch service.status {
        case .enabled:
            send(report)
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            report(.awaitingApproval)
            waitForApproval(report)
        default:
            report(.unavailable)
        }
    }

    private func waitForApproval(_ report: @escaping @MainActor (Outcome) -> Void) {
        let deadline = Date().addingTimeInterval(approvalWait)
        approvalTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, Date() < deadline else {
                    timer.invalidate()
                    return
                }
                if self.service.status == .enabled {
                    timer.invalidate()
                    self.send(report)
                }
            }
        }
    }

    /// Asks the helper. Just after it's allowed, launchd may not be running it yet, so a failure
    /// is retried a couple of times a second apart.
    private func send(_ report: @escaping @MainActor (Outcome) -> Void, attempts: Int = 3) {
        let connection = NSXPCConnection(machServiceName: LowPowerModeHelperID.label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: LowPowerModeSwitching.self)
        connection.resume()

        // XPC calls exactly one of the reply and the error handler, on its own queue.
        let finish: (Bool) -> Void = { [weak self] succeeded in
            connection.invalidate()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if succeeded {
                        report(.on)
                    } else if attempts > 1 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            MainActor.assumeIsolated { self?.send(report, attempts: attempts - 1) }
                        }
                    } else {
                        report(.unavailable)
                    }
                }
            }
        }
        guard let helper = connection.remoteObjectProxyWithErrorHandler({ _ in finish(false) })
                as? LowPowerModeSwitching else {
            finish(false)
            return
        }
        helper.turnOnLowPowerMode(reply: finish)
    }
}
#endif
