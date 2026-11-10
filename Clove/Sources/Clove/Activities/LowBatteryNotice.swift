import SwiftUI

/// Low battery, the way iOS 26 says it: the island drops a card below the camera, the level over
/// a hint on the left, the battery in a red pill on the right, its last bit of charge sending out
/// a ring every two seconds. Clicking switches Low Power Mode on and the card turns gold (the
/// direct build, through its helper; the App Store build can only open Battery settings, as
/// macOS lets only root change it).
struct LowBatteryNotice: View {
    let level: Int
    let lowPowerMode: LowPowerMode
    let notchSize: CGSize
    let onClick: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The view is new for each notice (it is keyed by the activity's id, which stays the same as
    /// Low Power Mode changes), so this is when the notice appeared.
    @State private var start = Date()

    var body: some View {
        Button(action: onClick) {
            VStack(spacing: 0) {
                Color.clear.frame(height: notchSize.height)
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(level)% Battery")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                        // Both lines live in a ZStack so they overlap as one blurs out and the
                        // next blurs in.
                        ZStack(alignment: .leading) {
                            Text(hint)
                                .font(.system(size: 12))
                                .foregroundStyle(lowPowerMode == .on ? LowBatteryStyle.gold.color : LowBatteryStyle.hint)
                                .id(lowPowerMode)
                                .transition(.noticeBlur(reduceMotion: reduceMotion))
                        }
                    }
                    .tracking(-0.2)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    TimelineView(.animation(paused: reduceMotion || lowPowerMode == .on)) { timeline in
                        LowBatteryPill(level: level, gold: lowPowerMode == .on ? 1 : 0,
                                       pulse: reduceMotion ? nil : timeline.date.timeIntervalSince(start))
                    }
                    .animation(reduceMotion ? nil : Motion.notice, value: lowPowerMode)
                }
                .padding(.leading, IslandLayout.noticeLeading)
                .padding(.trailing, IslandLayout.noticeInset)
                .padding(.top, IslandLayout.noticeTopGap)
                .padding(.bottom, IslandLayout.noticeInset)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(.subtle, hoverWash: false))
        .allowsHitTesting(lowPowerMode == .off)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(level)% battery. \(hint)")
    }

    private var hint: String {
        switch lowPowerMode {
        case .off: return "Click for Low Power Mode"
        case .approving: return "Allow Clove in Login Items"
        case .requested: return "Turn it on in Settings"
        case .on: return "Low Power Mode on"
        }
    }
}

/// The battery in its pill, drawn in iOS's 76 × 46 design units and scaled to fit. `gold` runs
/// from 0 (low: red) to 1 (Low Power Mode: gold) and animates; `pulse` is the time since the
/// notice appeared, nil for no pulse.
struct LowBatteryPill: View, Animatable {
    let level: Int
    var gold: Double
    let pulse: TimeInterval?

    var animatableData: Double {
        get { gold }
        set { gold = newValue }
    }

    // In design units: the pill, the battery inside it, and the charge inside the battery.
    private static let design = CGSize(width: 76, height: 46)
    private static let battery = CGRect(x: 16, y: 12, width: 40.4, height: 22)
    private static let terminal = CGRect(x: 57.85, y: 20.3, width: 2.15, height: 6)
    private static let chargeInset = CGSize(width: 3.9, height: 3.4)
    private static let chargeMinWidth: CGFloat = 6.46
    /// The ring grows from the charge's own size to a circle this wide.
    private static let ringDiameter: CGFloat = 35
    private static let ringWidth: CGFloat = 1.5

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / Self.design.width, y: size.height / Self.design.height)
            draw(in: &context)
        }
        .frame(width: IslandLayout.noticePillSize.width, height: IslandLayout.noticePillSize.height)
    }

    private func draw(in context: inout GraphicsContext) {
        typealias Style = LowBatteryStyle
        // The spring carries `gold` a little past 1; colours stop at gold.
        let gold = min(max(gold, 0), 1)
        let pill = CGRect(origin: .zero, size: Self.design)
        context.fill(Capsule().path(in: pill), with: .color(Style.pill.mix(Style.gold, gold).color))

        // Dim red body and terminal; in Low Power Mode they go solid black on the gold.
        let battery = Self.battery
        context.fill(RoundedRectangle(cornerRadius: 7.95, style: .continuous).path(in: battery),
                     with: .color(Style.body.mix(Style.black, gold).color))
        let terminal = UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0.6, bottomLeading: 0.6,
                                                                 bottomTrailing: 3, topTrailing: 3))
        context.fill(terminal.path(in: Self.terminal), with: .color(Style.terminal.mix(Style.black, gold).color))

        // The charge: a sliver at 10 or 20 %. It brightens as the ring goes out.
        let inner = battery.insetBy(dx: Self.chargeInset.width, dy: Self.chargeInset.height)
        let charge = CGRect(x: inner.minX, y: inner.minY,
                            width: max(Self.chargeMinWidth, inner.width * CGFloat(min(max(level, 0), 100)) / 100),
                            height: inner.height)
        let ring = pulse.map(Self.ring) ?? (progress: 0, opacity: 0, flash: 0)
        let red = Style.red.brightened(by: 0.5 * ring.flash * (1 - gold))
        context.fill(RoundedRectangle(cornerRadius: charge.width / 2, style: .continuous).path(in: charge),
                     with: .color(red.mix(Style.gold, gold).color))

        // The ring: from the charge's outline to a circle, fading in and out, gone once gold.
        let opacity = ring.opacity * (1 - gold)
        guard opacity > 0 else { return }
        let width = charge.width + (Self.ringDiameter - charge.width) * ring.progress
        let height = charge.height + (Self.ringDiameter - charge.height) * ring.progress
        let outline = CGRect(x: charge.midX - width / 2, y: charge.midY - height / 2, width: width, height: height)
            .insetBy(dx: -Self.ringWidth / 2, dy: -Self.ringWidth / 2)
        context.stroke(Capsule().path(in: outline), with: .color(Style.red.color.opacity(opacity)),
                       lineWidth: Self.ringWidth)
    }

    /// Where the ring is `elapsed` into the notice: it grows over `lowBatteryPulse` (linear, as a
    /// level would), its opacity and the charge's flash peaking halfway, then rests.
    private static func ring(_ elapsed: TimeInterval) -> (progress: CGFloat, opacity: Double, flash: Double) {
        let period = Motion.Duration.lowBatteryPulse + Motion.Duration.lowBatteryPulseRest
        let t = elapsed.truncatingRemainder(dividingBy: period) / Motion.Duration.lowBatteryPulse
        guard t < 1 else { return (1, 0, 0) }
        let peak = 1 - abs(2 * t - 1)
        return (CGFloat(t), peak, peak)
    }
}

/// The notice's colours: iOS's low-battery reds, and Clove's charging gold for Low Power Mode.
enum LowBatteryStyle {
    struct RGBA {
        var red, green, blue, alpha: Double

        var color: Color { Color(red: red, green: green, blue: blue).opacity(alpha) }

        func mix(_ other: RGBA, _ amount: Double) -> RGBA {
            func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * amount }
            return RGBA(red: lerp(red, other.red), green: lerp(green, other.green),
                        blue: lerp(blue, other.blue), alpha: lerp(alpha, other.alpha))
        }

        /// Like a CSS brightness filter: each channel scaled by 1 + `amount`, capped at white.
        func brightened(by amount: Double) -> RGBA {
            RGBA(red: min(1, red * (1 + amount)), green: min(1, green * (1 + amount)),
                 blue: min(1, blue * (1 + amount)), alpha: alpha)
        }
    }

    static let red = RGBA(red: 1, green: 0.31, blue: 0.36, alpha: 1)
    static let pill = RGBA(red: 0.2, green: 0.05, blue: 0.055, alpha: 1)
    static let body = RGBA(red: 0.58, green: 0.14, blue: 0.165, alpha: 0.35)
    static let terminal = RGBA(red: 0.56, green: 0.14, blue: 0.16, alpha: 0.4)
    static let black = RGBA(red: 0, green: 0, blue: 0, alpha: 1)
    static let gold = RGBA(red: 1, green: 0.82, blue: 0.24, alpha: 1)
    static let hint = Color.white.opacity(0.5)
}
