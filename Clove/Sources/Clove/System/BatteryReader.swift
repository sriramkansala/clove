import Foundation
import IOKit

/// One snapshot of the Mac's power: what the charger is delivering, what the battery is doing,
/// and what the Mac is using. Read from the battery's IORegistry entry, the same data
/// `ioreg -rn AppleSmartBattery` shows, with the SMC's live power figures on top in the
/// direct-download build.
struct BatteryReading: Equatable {
    var percent: Int
    var isPluggedIn: Bool
    var isCharging: Bool
    var isFull: Bool

    /// Power arriving from the charger right now.
    var inputVolts: Double?
    var inputAmps: Double?
    var inputWatts: Double?

    /// The charger's rating and the voltage it negotiated (USB-C PD: 5, 9, 15 or 20 V).
    var chargerWatts: Int?
    var chargerVolts: Double?

    /// Battery terminal voltage and current; current and power are positive while charging.
    var batteryVolts: Double
    var batteryAmps: Double
    var batteryWatts: Double

    /// Everything the Mac is drawing, from charger and battery together.
    var systemWatts: Double?

    var minutesToFull: Int?
    var minutesToEmpty: Int?
    var cycleCount: Int?
    /// Full-charge capacity as a share of design capacity.
    var healthPercent: Int?
}

enum BatteryReader {
    /// The current reading, or nil on a Mac without a battery.
    static func read() -> BatteryReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let battery = properties?.takeRetainedValue() as? [String: Any]
        else { return nil }

        // Signed values (current, battery power) come through as 64-bit two's complement.
        func number(_ key: String, in dictionary: [String: Any]) -> Int64? {
            (dictionary[key] as? NSNumber)?.int64Value
        }
        func flag(_ key: String) -> Bool { (battery[key] as? NSNumber)?.boolValue ?? false }
        // 65535 means "not known yet".
        func minutes(_ key: String, in dictionary: [String: Any]) -> Int? {
            number(key, in: dictionary).flatMap { $0 > 0 && $0 < 65_535 ? Int($0) : nil }
        }

        let telemetry = battery["PowerTelemetryData"] as? [String: Any] ?? [:]
        let adapter = battery["AdapterDetails"] as? [String: Any] ?? [:]
        let details = battery["BatteryData"] as? [String: Any] ?? [:]
        let pluggedIn = flag("ExternalConnected")
        // The registry's power figures refresh about once a minute; the SMC's about every second, so
        // they follow the watts as they climb after plugging in. They take over whenever they're readable.
        #if DIRECT
        let live = SMC.livePower()
        #else
        let live: LivePower? = nil
        #endif

        // The telemetry can be briefly inconsistent (e.g. right after switching chargers),
        // so missing power falls back to volts × amps and invalid values are dropped.
        let registryVolts = number("SystemVoltageIn", in: telemetry).map { Double($0) / 1000 }.flatMap { $0 > 0 ? $0 : nil }
        let registryAmps = number("SystemCurrentIn", in: telemetry).map { Double($0) / 1000 }.flatMap { $0 >= 0 ? $0 : nil }
        let registryWatts = number("SystemPowerIn", in: telemetry).map { Double($0) / 1000 }.flatMap { $0 > 0 ? $0 : nil }
            ?? registryVolts.flatMap { volts in registryAmps.map { volts * $0 } }
        let inputVolts = pluggedIn ? live.map(\.inputVolts) ?? registryVolts : nil
        let inputAmps = pluggedIn ? live.map(\.inputAmps) ?? registryAmps : nil
        let inputWatts = pluggedIn ? live.map(\.inputWatts) ?? registryWatts : nil

        let batteryVolts = live?.batteryVolts ?? Double(number("Voltage", in: battery) ?? 0) / 1000
        let batteryAmps = live?.batteryAmps ?? Double(number("Amperage", in: battery) ?? 0) / 1000
        let reportedBattery = live == nil ? number("BatteryPower", in: telemetry).map { Double($0) / 1000 } : nil
        // Trust the battery's own power figure only when its direction matches the current.
        let batteryWatts = reportedBattery.flatMap { watts in
            batteryAmps == 0 || (watts > 0) == (batteryAmps > 0) ? watts : nil
        } ?? batteryVolts * batteryAmps

        let design = number("DesignCapacity", in: battery) ?? number("DesignCapacity", in: details)
        let full = number("AppleRawMaxCapacity", in: battery) ?? number("FullChargeCapacity", in: details)

        return BatteryReading(
            percent: Int(number("CurrentCapacity", in: battery) ?? 0),
            isPluggedIn: pluggedIn,
            isCharging: flag("IsCharging"),
            isFull: flag("FullyCharged"),
            inputVolts: inputVolts,
            inputAmps: inputAmps,
            inputWatts: inputWatts,
            chargerWatts: pluggedIn ? number("Watts", in: adapter).map(Int.init) : nil,
            chargerVolts: pluggedIn ? number("AdapterVoltage", in: adapter).map { Double($0) / 1000 } : nil,
            batteryVolts: batteryVolts,
            batteryAmps: batteryAmps,
            batteryWatts: batteryWatts,
            systemWatts: (live?.systemWatts ?? number("SystemLoad", in: telemetry).map { Double($0) / 1000 }).flatMap { $0 > 0 ? $0 : nil },
            minutesToFull: minutes("AvgTimeToFull", in: battery),
            minutesToEmpty: pluggedIn ? nil : minutes("AvgTimeToEmpty", in: details) ?? minutes("TimeRemaining", in: battery),
            cycleCount: number("CycleCount", in: battery).map(Int.init),
            healthPercent: design.flatMap { design in full.map { Int((Double($0) / Double(design) * 100).rounded()) } }
        )
    }
}

/// Live power figures from the SMC.
struct LivePower {
    var inputVolts: Double
    var inputAmps: Double
    var inputWatts: Double
    var systemWatts: Double
    /// Positive while charging, like the registry's.
    var batteryVolts: Double
    var batteryAmps: Double
}

#if DIRECT
/// The System Management Controller's live power sensors, refreshed about every second.
/// Direct-download build only: its keys are undocumented, and opening it from the sandbox needs a
/// temporary-exception entitlement, so the App Store binary leaves it out and uses the registry.
/// On a Mac whose sensors differ, `livePower()` is nil and the registry figures are used.
enum SMC {
    /// Everything at once, or nil if any of it can't be read.
    static func livePower() -> LivePower? {
        guard let inputVolts = float("VD0R"), let inputAmps = float("ID0R"), let inputWatts = float("PDTR"),
              let systemWatts = float("PSTR"), let batteryMillivolts = int16("B0AV"), let batteryMilliamps = int16("B0AC")
        else { return nil }
        return LivePower(
            inputVolts: max(inputVolts, 0), inputAmps: max(inputAmps, 0), inputWatts: max(inputWatts, 0),
            systemWatts: systemWatts, batteryVolts: batteryMillivolts / 1000, batteryAmps: batteryMilliamps / 1000
        )
    }

    private static let connection: io_connect_t? = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        return IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS ? connection : nil
    }()

    private static func float(_ key: String) -> Double? {
        guard let (type, bytes) = read(key), type == "flt ", bytes.count == 4 else { return nil }
        return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
    }

    /// Apple silicon stores these little-endian.
    private static func int16(_ key: String) -> Double? {
        guard let (type, bytes) = read(key), type == "si16" || type == "ui16", bytes.count == 2 else { return nil }
        let raw = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        return Double(type == "si16" ? Int(Int16(bitPattern: raw)) : Int(raw))
    }

    // The request and reply share one 80-byte layout (SMCKeyData_t); these are the offsets used.
    private static let blockSize = 80, keyOffset = 0, sizeOffset = 28, typeOffset = 32, resultOffset = 40, commandOffset = 42, dataOffset = 48
    private static let readKeyCommand: UInt8 = 5, keyInfoCommand: UInt8 = 9

    /// A key's type (e.g. "flt ") and raw bytes.
    private static func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        guard let connection else { return nil }
        let code = key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        func call(_ command: UInt8, size: UInt32 = 0) -> [UInt8]? {
            var request = [UInt8](repeating: 0, count: blockSize)
            withUnsafeBytes(of: code) { request.replaceSubrange(keyOffset..<keyOffset + 4, with: $0) }
            withUnsafeBytes(of: size) { request.replaceSubrange(sizeOffset..<sizeOffset + 4, with: $0) }
            request[commandOffset] = command
            var reply = [UInt8](repeating: 0, count: blockSize)
            var replySize = blockSize
            // Selector 2 is the SMC's single entry point; the command byte says what to do.
            let result = IOConnectCallStructMethod(connection, 2, request, blockSize, &reply, &replySize)
            return result == KERN_SUCCESS && reply[resultOffset] == 0 ? reply : nil
        }
        func word(_ block: [UInt8], at offset: Int) -> UInt32 {
            block[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        guard let info = call(keyInfoCommand) else { return nil }
        let size = word(info, at: sizeOffset)
        guard size <= 32, let value = call(readKeyCommand, size: size) else { return nil }
        let type = String(decoding: withUnsafeBytes(of: word(info, at: typeOffset).bigEndian, Array.init), as: UTF8.self)
        return (type, Array(value[dataOffset..<dataOffset + Int(size)]))
    }
}
#endif

/// What the power situation is, in words and color.
enum PowerState: Equatable {
    case charging, connecting, chargerShort, noInput, notCharging, onBattery

    /// Right after plugging in, the charger is still negotiating and the registry's figures can be up to
    /// a minute old, so a draining battery then means "not yet", not "no power" or "can't keep up".
    static let connectingGrace: TimeInterval = 60

    init(_ reading: BatteryReading, pluggedInAt: Date? = nil, at date: Date = Date()) {
        if !reading.isPluggedIn {
            self = .onBattery
        } else if reading.batteryWatts < -0.5, let pluggedInAt, date.timeIntervalSince(pluggedInAt) < Self.connectingGrace {
            self = .connecting
        } else if (reading.inputWatts ?? 0) < 1, reading.batteryWatts < -0.5 {
            self = .noInput  // connected, but nothing is coming in: cable, charger or negotiation
        } else if reading.batteryWatts < -0.5 {
            self = .chargerShort  // plugged in, but the Mac draws more than the charger gives
        } else if reading.batteryWatts > 0.5 || (reading.isCharging && reading.percent < 100) {
            self = .charging
        } else {
            self = .notCharging
        }
    }

    var title: String {
        switch self {
        case .charging: return "Charging"
        case .connecting: return "Connecting"
        case .chargerShort: return "Can't keep up"
        case .noInput: return "No power in"
        case .notCharging: return "Not charging"
        case .onBattery: return "On battery"
        }
    }

    var symbol: String {
        switch self {
        case .charging: return "bolt.fill"
        case .connecting: return "bolt.badge.clock.fill"
        case .chargerShort: return "exclamationmark.triangle.fill"
        case .noInput: return "bolt.slash.fill"
        case .notCharging: return "powerplug.fill"
        case .onBattery: return "battery.75percent"
        }
    }
}
