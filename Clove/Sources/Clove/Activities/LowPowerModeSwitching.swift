#if DIRECT
import Foundation

/// What Clove's helper does: switch Low Power Mode, which macOS lets only root change.
///
/// Direct-download build only (`DIRECT`): the helper is a launchd daemon running as root, and
/// the App Store doesn't allow apps to raise their privileges. This file is compiled into both
/// the app and the helper (scripts/embed-helper.sh), so they agree on the interface and names.
@objc protocol LowPowerModeSwitching {
    /// Turns Low Power Mode on for battery power; replies whether it was set.
    func turnOnLowPowerMode(reply: @escaping (Bool) -> Void)
}

enum LowPowerModeHelperID {
    /// The launchd label and the helper's XPC service name.
    static let label = "app.clove.Clove.direct.helper"
    /// The helper's launchd plist, in Contents/Library/LaunchDaemons.
    static let plistName = "\(label).plist"
    /// The only app the helper talks to.
    static let client = "app.clove.Clove.direct"
}
#endif
