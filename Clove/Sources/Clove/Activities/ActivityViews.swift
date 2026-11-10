import SwiftUI

/// A transient activity beside the notch: an icon in the left wing, a value in the right wing,
/// and — for volume and brightness — a level meter along the island's bottom edge, so the island
/// itself becomes the gauge. A charger connecting gets its own moment, `ChargingSweep`, and low
/// battery its own notice, `LowBatteryNotice`.
struct TransientActivityView: View {
    let activity: TransientActivity
    let notchSize: CGSize
    let wingWidth: CGFloat
    /// Height of the strip below the notch that holds the meter (0 = no meter).
    let meterHeight: CGFloat
    /// The low-battery notice was clicked.
    var onRequestLowPowerMode: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch activity.kind {
        case .charging(let level):
            ChargingSweep(level: level, notchSize: notchSize, wingWidth: wingWidth, stageHeight: meterHeight)
        case .lowBattery(let level, let lowPowerMode):
            LowBatteryNotice(level: level, lowPowerMode: lowPowerMode, notchSize: notchSize,
                             onClick: onRequestLowPowerMode)
        default:
            wingsAndMeter
        }
    }

    private var wingsAndMeter: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leftWing
                    .padding(.leading, 12)
                    .frame(width: wingWidth, height: notchSize.height, alignment: .leading)

                Color.clear
                    .frame(width: notchSize.width, height: notchSize.height)

                rightWing
                    .padding(.trailing, 12)
                    .frame(width: wingWidth, height: notchSize.height, alignment: .trailing)
            }

            if meterHeight > 0, let meter {
                LevelMeter(level: meter.level, color: meter.color, dimmed: meter.dimmed)
                    .frame(height: meterHeight, alignment: .top)
            }
        }
    }

    // MARK: Wings

    @ViewBuilder
    private var leftWing: some View {
        switch activity.kind {
        case .volume(let level, let muted):
            Image(systemName: muted || level == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill",
                  variableValue: Double(level))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        case .brightness(let level):
            Image(systemName: level < 0.5 ? "sun.min.fill" : "sun.max.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
        case .charging, .lowBattery:
            EmptyView()  // ChargingSweep and LowBatteryNotice draw their own.
        case .audioDevice(let name):
            icon(Self.audioSymbol(for: name), .white)
        case .taskDue(let title, let overdue):
            HStack(spacing: 5) {
                icon("checklist", overdue ? .red : .orange)
                Text(title)
                    .font(Self.valueFont)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    @ViewBuilder
    private var rightWing: some View {
        switch activity.kind {
        case .volume(let level, let muted):
            // The number is a derived value: the text is always the final value; only its
            // digits roll, on base, so correctness never depends on the animation.
            Text("\(Int(((muted ? 0 : level) * 100).rounded()))")
                .font(Self.valueFont)
                .foregroundStyle(.white.opacity(muted ? 0.5 : 1))
                .contentTransition(.numericText(value: Double(level)))
                .animation(reduceMotion ? nil : Motion.base, value: level)
        case .brightness(let level):
            Text("\(Int((level * 100).rounded()))")
                .font(Self.valueFont)
                .foregroundStyle(.white)
                .contentTransition(.numericText(value: Double(level)))
                .animation(reduceMotion ? nil : Motion.base, value: level)
        case .charging, .lowBattery:
            EmptyView()
        case .audioDevice(let name):
            Text(name)
                .font(Self.valueFont)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
        case .taskDue(_, let overdue):
            value(overdue ? "Overdue" : "Due today", overdue ? .red : .orange)
        }
    }

    private static let valueFont = Font.system(size: 12, weight: .semibold).monospacedDigit()

    private func icon(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
    }

    private func value(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(Self.valueFont)
            .foregroundStyle(color)
    }

    // MARK: Meter

    private var meter: (level: Double, color: Color, dimmed: Bool)? {
        switch activity.kind {
        case .volume(let level, let muted): return (Double(level), .white, muted)
        case .brightness(let level): return (Double(level), .white, false)
        case .charging, .lowBattery, .audioDevice, .taskDue: return nil
        }
    }

    static func audioSymbol(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpods.max" }
        if lower.contains("airpods pro") { return "airpods.pro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") { return "beats.headphones" }
        return "headphones"
    }
}

/// A 3 pt line along the island's bottom edge, inset clear of the rounded corners, filled to
/// `level` with a soft glow. It follows the keys, so it springs (`Motion.snappy`).
private struct LevelMeter: View {
    let level: Double
    let color: Color
    let dimmed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let thickness: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(color.opacity(0.18))
                Capsule()
                    .fill(color.opacity(dimmed ? 0.35 : 1))
                    .frame(width: max(thickness, width * min(max(level, 0), 1)))
                    .shadow(color: color.opacity(dimmed ? 0 : 0.55), radius: 3)
            }
            .frame(height: thickness)
            .animation(reduceMotion ? nil : Motion.snappy, value: level)
            .animation(reduceMotion ? nil : Motion.fast, value: dimmed)
        }
        .frame(height: thickness)
        .padding(.horizontal, 14)
        .padding(.top, 1)
    }
}
