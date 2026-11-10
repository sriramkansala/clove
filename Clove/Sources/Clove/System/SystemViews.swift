import SwiftUI

// MARK: - System page

/// The island's System page: a battery tile above CPU and memory tiles, then a line of smaller
/// figures. Macs without a battery show only the performance tiles. Sizes come from
/// `IslandLayout`, so the model can size the island to match.
struct SystemPageView: View {
    @ObservedObject var system: SystemMonitor

    var body: some View {
        SystemDetails(reading: system.battery, state: system.powerState, cpu: system.cpu,
                      memory: system.memory, gpuPercent: system.gpuPercent, network: system.network,
                      diskFreeBytes: system.diskFreeBytes, thermalState: system.thermalState)
    }
}

struct SystemDetails: View {
    let reading: BatteryReading?
    let state: PowerState?
    let cpu: CPUUsage?
    let memory: MemoryUsage?
    let gpuPercent: Int?
    let network: NetworkRate?
    let diskFreeBytes: Int64?
    let thermalState: ProcessInfo.ThermalState

    var body: some View {
        VStack(alignment: .leading, spacing: IslandLayout.systemTileGap) {
            if let reading, let state {
                BatteryTile(reading: reading, state: state)
            }
            HStack(spacing: IslandLayout.systemTileGap) {
                CPUTile(cpu: cpu)
                MemoryTile(memory: memory)
            }
            FooterLine(gpuPercent: gpuPercent, network: network, diskFreeBytes: diskFreeBytes,
                       thermalState: thermalState)
                .padding(.top, IslandLayout.systemFooterGap - IslandLayout.systemTileGap)
                .padding(.horizontal, IslandLayout.systemTilePadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Shared pieces

private enum SystemStyle {
    static let tile = Color.white.opacity(0.06)
    static let track = Color.white.opacity(0.08)
    static let label = Color.white.opacity(0.6)
    static let note = Color.white.opacity(0.45)
    static let cpu = Color(red: 0.42, green: 0.73, blue: 1.0)
    static let memory = Color(red: 0.75, green: 0.58, blue: 1.0)
}

/// A rounded tile; everything on the page sits in one, so groups read without dividers.
private struct Tile<Content: View>: View {
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, IslandLayout.systemTilePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(SystemStyle.tile,
                        in: RoundedRectangle(cornerRadius: IslandLayout.systemTileRadius, style: .continuous))
    }
}

/// A tile's header: a tinted glyph and the metric's name, a note on the right.
private struct TileHeader: View {
    let symbol: String
    let title: String
    let tint: Color
    let note: String
    var noteColor: Color = SystemStyle.note

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SystemStyle.label)
            Spacer(minLength: 6)
            Text(note)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(noteColor)
                .lineLimit(1)
        }
        .frame(height: IslandLayout.systemTileHeaderHeight)
    }
}

/// A tile's headline figure: large digits, a small unit.
private struct Figure: View {
    let value: String
    let unit: String
    /// Drives the rolling digits.
    let amount: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1.5) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText(value: amount))
                .animation(reduceMotion ? nil : Motion.base, value: amount)
            Text(unit)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(SystemStyle.label)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// Header above, figure and its graphic below; the graphic sits on the figure's baseline.
private struct MetricTile<Graphic: View>: View {
    let header: TileHeader
    let figure: Figure
    @ViewBuilder let graphic: Graphic

    var body: some View {
        Tile(height: IslandLayout.systemTileHeight) {
            VStack(alignment: .leading, spacing: IslandLayout.systemTileHeaderGap) {
                header
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    figure
                    graphic
                        .frame(maxWidth: .infinity)
                        .alignmentGuide(.lastTextBaseline) { $0[.bottom] }
                }
                .frame(height: IslandLayout.systemTileBodyHeight, alignment: .bottom)
            }
        }
    }
}

// MARK: - Battery

/// The battery in one tile: charge, what the power is doing and how long
/// it has, then what the charger delivers, what the battery is doing and what the Mac is using.
/// While plugged in, the tile takes on the state's colour.
private struct BatteryTile: View {
    let reading: BatteryReading
    let state: PowerState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color {
        guard state == .onBattery else { return state.color }
        return reading.percent <= 10 ? .red : reading.percent <= 20 ? .orange : .white
    }

    /// On battery, the glyph shows the level too.
    private var symbol: String {
        guard state == .onBattery else { return state.symbol }
        switch reading.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var body: some View {
        Tile(height: IslandLayout.systemBatteryTileHeight) {
            HStack(spacing: 12) {
                Figure(value: "\(reading.percent)", unit: "%", amount: Double(reading.percent))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: symbol)
                        Text(state.title)
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(accent)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(SystemStyle.note)
                    }
                }
                .lineLimit(1)
                // Takes what the figures leave, and truncates first.
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) {
                    if reading.isPluggedIn {
                        PowerColumn(label: "Charger",
                                    value: PowerFormat.watts(reading.inputWatts),
                                    amount: reading.inputWatts ?? 0,
                                    color: state == .noInput ? .red : ChargingStyle.gold)
                    }
                    PowerColumn(label: "Battery",
                                value: PowerFormat.signedWatts(reading.batteryWatts),
                                amount: reading.batteryWatts,
                                color: reading.batteryWatts > 0.5 ? ChargingStyle.gold
                                    : reading.batteryWatts < -0.5 ? .orange : SystemStyle.label)
                    if let system = reading.systemWatts {
                        PowerColumn(label: "Mac", value: PowerFormat.watts(system), amount: system, color: .white)
                    }
                }
            }
        }
        .background(state == .onBattery ? Color.clear : state.color.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: IslandLayout.systemTileRadius, style: .continuous))
        .animation(reduceMotion ? nil : Motion.base, value: state)
    }

    private var detail: String? {
        if reading.isPluggedIn, reading.percent < 100, let minutes = reading.minutesToFull {
            return "Full in \(PowerFormat.duration(minutes))"
        }
        if !reading.isPluggedIn, let minutes = reading.minutesToEmpty {
            return "\(PowerFormat.duration(minutes)) left"
        }
        // Why it can't keep up.
        if state == .chargerShort, let watts = reading.chargerWatts {
            return "\(watts) W charger"
        }
        return reading.healthPercent.map { "\($0)% health" }
    }
}

extension PowerState {
    var color: Color {
        switch self {
        case .charging, .connecting: return ChargingStyle.gold
        case .chargerShort: return .orange
        case .noInput: return .red
        case .notCharging: return .teal
        case .onBattery: return .secondary
        }
    }
}

/// One power figure: what it is above, the watts below.
private struct PowerColumn: View {
    let label: String
    let value: String
    /// The watts behind `value`, so its digits roll up or down as it changes.
    let amount: Double
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(SystemStyle.note)
            Text(value)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
                .contentTransition(.numericText(value: amount))
                .animation(reduceMotion ? nil : Motion.base, value: amount)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

private enum PowerFormat {
    static func watts(_ value: Double?) -> String {
        guard let value else { return "— W" }
        return String(format: value >= 100 ? "%.0f W" : "%.1f W", value)
    }

    static func signedWatts(_ value: Double) -> String {
        abs(value) < 0.05 ? "0 W" : String(format: "%+.1f W", value)
    }

    static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

// MARK: - Performance

private struct CPUTile: View {
    let cpu: CPUUsage?

    var body: some View {
        MetricTile(header: TileHeader(symbol: "cpu", title: "CPU", tint: SystemStyle.cpu,
                                      note: cpu.map { "\($0.busyCores) of \($0.cores.count) cores busy" } ?? ""),
                   figure: Figure(value: cpu.map { "\(Int(($0.total * 100).rounded()))" } ?? "—",
                                  unit: "%", amount: cpu?.total ?? 0)) {
            CoreBars(cpu: cpu)
                .frame(height: IslandLayout.systemMeterHeight)
        }
    }
}

/// One bar per core, spread across the tile, efficiency cores set slightly apart from
/// performance cores. Busy cores are solid, so the count in the header can be read straight off
/// the bars.
private struct CoreBars: View {
    let cpu: CPUUsage?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let maxBarWidth: CGFloat = 7
    private static let clusterGap: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let cores = cpu?.cores ?? []
            let efficiency = cpu?.efficiencyCoreCount ?? 0
            let split = efficiency > 0 && efficiency < cores.count
            let count = CGFloat(max(cores.count, 1))
            let usable = geometry.size.width - (split ? Self.clusterGap : 0)
            // Gaps of at least 0.6 of a bar; bars no wider than `maxBarWidth`.
            let barWidth = min(Self.maxBarWidth, usable / (1.6 * count - 0.6))
            let spacing = count > 1 ? (usable - barWidth * count) / (count - 1) : 0
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(cores.indices, id: \.self) { index in
                    CoreBar(level: cores[index], height: geometry.size.height)
                        .frame(width: barWidth)
                        .padding(.leading, split && index == efficiency ? Self.clusterGap : 0)
                }
            }
            .animation(reduceMotion ? nil : Motion.base, value: cores)
        }
    }
}

private struct CoreBar: View {
    let level: Double
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            Capsule(style: .continuous)
                .fill(SystemStyle.track)
            Capsule(style: .continuous)
                .fill(SystemStyle.cpu.opacity(level >= CPUUsage.busyThreshold ? 1 : 0.4))
                .frame(height: max(3, height * level))
        }
    }
}

private struct MemoryTile: View {
    let memory: MemoryUsage?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MetricTile(header: TileHeader(symbol: "memorychip", title: "Memory", tint: tint,
                                      note: note, noteColor: pressureColor ?? SystemStyle.note),
                   figure: Figure(value: memory.map { ByteFormat.gigabytes($0.usedBytes) } ?? "—",
                                  unit: "GB", amount: memory?.fraction ?? 0)) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(SystemStyle.track)
                    Capsule(style: .continuous)
                        .fill(tint)
                        .frame(width: max(IslandLayout.systemBarHeight, geometry.size.width * (memory?.fraction ?? 0)))
                }
                .animation(reduceMotion ? nil : Motion.base, value: memory?.fraction)
            }
            .frame(height: IslandLayout.systemBarHeight)
        }
    }

    private var tint: Color { pressureColor ?? SystemStyle.memory }

    /// Under pressure the note says so, so colour is never the only signal.
    private var note: String {
        switch memory?.pressure {
        case .warning: return "High pressure"
        case .critical: return "Critical pressure"
        default: return memory.map { "of \(ByteFormat.wholeGigabytes($0.totalBytes)) GB" } ?? ""
        }
    }

    private var pressureColor: Color? {
        switch memory?.pressure {
        case .warning: return .orange
        case .critical: return .red
        default: return nil
        }
    }
}

/// The smaller figures, as one quiet line: GPU, network, free disk, and heat when there is any.
private struct FooterLine: View {
    let gpuPercent: Int?
    let network: NetworkRate?
    let diskFreeBytes: Int64?
    let thermalState: ProcessInfo.ThermalState

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Text("·")
                        .foregroundStyle(Color.white.opacity(0.25))
                        .padding(.horizontal, 7)
                }
                HStack(spacing: 3) {
                    Text(item.label).foregroundStyle(SystemStyle.note)
                    Text(item.value).foregroundStyle(SystemStyle.label)
                }
            }
            Spacer(minLength: 6)
            if let thermal = thermalLabel {
                HStack(spacing: 3) {
                    Image(systemName: "thermometer.high")
                    Text(thermal)
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.orange)
            }
        }
        .font(.system(size: 10.5).monospacedDigit())
        .lineLimit(1)
        .frame(height: IslandLayout.systemFooterHeight)
    }

    private var items: [(label: String, value: String)] {
        var items: [(label: String, value: String)] = []
        if let gpuPercent { items.append(("GPU", "\(gpuPercent)%")) }
        if let network {
            items.append(("↓", ByteFormat.rate(network.downBytesPerSecond)))
            items.append(("↑", ByteFormat.rate(network.upBytesPerSecond)))
        }
        if let diskFreeBytes { items.append(("Disk", "\(ByteFormat.diskSpace(diskFreeBytes)) free")) }
        return items
    }

    /// Only when the Mac is actually hot: "nominal" and "fair" are not worth the space.
    private var thermalLabel: String? {
        switch thermalState {
        case .serious: return "Hot"
        case .critical: return "Very hot"
        default: return nil
        }
    }
}

private enum ByteFormat {
    private static let gibibyte = 1_073_741_824.0

    /// Memory, in the binary gigabytes Activity Monitor uses, without the unit: "32.7".
    static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / gibibyte)
    }

    static func wholeGigabytes(_ bytes: UInt64) -> String {
        String(format: "%.0f", Double(bytes) / gibibyte)
    }

    /// Disk space, in the decimal gigabytes Finder uses: "695 GB", "1.2 TB".
    static func diskSpace(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1e9
        return gigabytes >= 1000 ? String(format: "%.1f TB", gigabytes / 1000) : String(format: "%.0f GB", gigabytes)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let kilobytes = bytesPerSecond / 1000
        return kilobytes >= 1000 ? String(format: "%.1f MB/s", kilobytes / 1000) : String(format: "%.0f KB/s", kilobytes)
    }
}
