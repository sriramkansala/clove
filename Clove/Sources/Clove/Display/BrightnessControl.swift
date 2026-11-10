#if DIRECT
import CoreGraphics
import Foundation

/// Built-in display brightness through Apple's private DisplayServices framework.
///
/// Direct-download build only (`DIRECT`): there is no public API for this on Apple silicon, and
/// the App Store rejects private API use, so the App Store binary must not contain any of it —
/// not even the symbol names, which App Review scans for. Loaded with `dlopen` so a future
/// macOS without these functions just disables brightness instead of failing to launch.
enum BrightnessControl {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool

    private struct Functions {
        let get: GetBrightness
        let set: SetBrightness
        let canChange: CanChangeBrightness
    }

    private static let functions: Functions? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness"),
              let canChange = dlsym(handle, "DisplayServicesCanChangeBrightness")
        else { return nil }
        return Functions(get: unsafeBitCast(get, to: GetBrightness.self),
                         set: unsafeBitCast(set, to: SetBrightness.self),
                         canChange: unsafeBitCast(canChange, to: CanChangeBrightness.self))
    }()

    /// The built-in display, if it is online (lid open) and its brightness can be changed.
    static var builtInDisplay: CGDirectDisplayID? {
        guard let functions else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 && functions.canChange($0) }
    }

    /// Brightness 0...1, or nil if it cannot be read.
    static func brightness(of display: CGDirectDisplayID) -> Float? {
        guard let functions else { return nil }
        var value: Float = 0
        return functions.get(display, &value) == 0 ? value : nil
    }

    static func setBrightness(_ value: Float, of display: CGDirectDisplayID) {
        _ = functions?.set(display, min(max(value, 0), 1))
    }
}
#endif
