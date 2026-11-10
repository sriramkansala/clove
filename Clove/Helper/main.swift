import Foundation
import Security

// Clove's helper: a launchd daemon, run as root, that switches Low Power Mode when the
// low-battery notice is clicked (macOS lets only root change it). Direct-download build only;
// scripts/embed-helper.sh builds it into Clove.app and Clove registers it with SMAppService.
//
// It takes requests only from Clove signed by the same team as itself, and can do nothing but
// turn Low Power Mode on for battery power.

final class Helper: NSObject, NSXPCListenerDelegate, LowPowerModeSwitching {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: LowPowerModeSwitching.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    /// On battery power only, as "Only on Battery" in Battery settings: the notice appears on
    /// battery, and plugging in gives the Mac its full speed back. Macs with Energy Modes (Low
    /// Power, Automatic, High Power) keep the setting in pmset's `powermode`, where 1 is Low
    /// Power; other Macs in `lowpowermode`.
    func turnOnLowPowerMode(reply: @escaping (Bool) -> Void) {
        let settings = pmset(["-g", "custom"]).output
        let hasEnergyModes = settings.split(separator: "\n").contains {
            $0.split(separator: " ").first == "powermode"
        }
        reply(pmset(["-b", hasEnergyModes ? "powermode" : "lowpowermode", "1"]).succeeded)
    }

    private func pmset(_ arguments: [String]) -> (succeeded: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        do {
            try process.run()
        } catch {
            return (false, "")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }
}

/// The team that signed this helper, or nil if it isn't signed by one.
func ownTeam() -> String? {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let info = info as? [String: Any]
    else { return nil }
    return info[kSecCodeInfoTeamIdentifier as String] as? String
}

// An ad-hoc signed helper can't tell Clove from anything else, so it serves no one.
guard let team = ownTeam() else { exit(1) }

let listener = NSXPCListener(machServiceName: LowPowerModeHelperID.label)
listener.setConnectionCodeSigningRequirement(
    "anchor apple generic and identifier \"\(LowPowerModeHelperID.client)\" and certificate leaf[subject.OU] = \"\(team)\""
)
let helper = Helper()
listener.delegate = helper
listener.resume()
dispatchMain()
