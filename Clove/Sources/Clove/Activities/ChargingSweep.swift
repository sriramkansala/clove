import SwiftUI

/// The charging colours: gold, warming to white-hot.
enum ChargingStyle {
    static let gold = Color(red: 1.0, green: 0.82, blue: 0.24)
    static let hot = Color(red: 1.0, green: 0.97, blue: 0.86)
}

/// The charger just connected: a band of gold light falls through the island from top to bottom,
/// lighting the bolt and the level as it passes, and lands as a line that narrows and breathes
/// while the activity shows. With Reduce Motion the island shows the line at rest.
struct ChargingSweep: View {
    let level: Int
    let notchSize: CGSize
    let wingWidth: CGFloat
    /// Height of the island below the camera.
    let stageHeight: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The view is new for each activity (it is keyed by the activity's id), so this is when the
    /// charger connected.
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            ChargingSweepFrame(level: level, notchSize: notchSize, wingWidth: wingWidth,
                               stageHeight: stageHeight,
                               elapsed: reduceMotion ? nil : timeline.date.timeIntervalSince(start))
        }
    }
}

/// One moment of the sweep; `elapsed` is the time since the charger connected, nil for at rest.
struct ChargingSweepFrame: View {
    let level: Int
    let notchSize: CGSize
    let wingWidth: CGFloat
    let stageHeight: CGFloat
    let elapsed: TimeInterval?

    /// The line's distance from the island's bottom edge.
    private static let landingInset: CGFloat = 5
    /// How far the band's wash reaches above its line.
    private static let washHeight: CGFloat = 23

    var body: some View {
        let height = notchSize.height + stageHeight
        let landing = height - Self.landingInset
        let state = SweepState(elapsed: elapsed)
        let bandY = landing * state.fall
        ZStack(alignment: .top) {
            Canvas { context, size in
                Self.draw(state, bandY: bandY, in: &context, size: size)
            }
            HStack(spacing: 0) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 12)
                    .frame(width: wingWidth, height: notchSize.height, alignment: .leading)
                Color.clear
                    .frame(width: notchSize.width, height: notchSize.height)
                Text("\(level)%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .padding(.trailing, 12)
                    .frame(width: wingWidth, height: notchSize.height, alignment: .trailing)
            }
            .foregroundStyle(ChargingStyle.gold)
            // Lit as the band passes them.
            .opacity(min(1, max(0.12, (bandY - notchSize.height / 2 + 8) / 16)))
        }
        .frame(height: height, alignment: .top)
        .allowsHitTesting(false)
    }

    private static func draw(_ state: SweepState, bandY: CGFloat, in context: inout GraphicsContext, size: CGSize) {
        let centerX = size.width / 2

        // The wash the band leaves above itself, fading as it lands.
        let washTop = bandY - washHeight
        context.fill(Path(CGRect(x: 0, y: washTop, width: size.width, height: washHeight)),
                     with: .linearGradient(
                        Gradient(colors: [ChargingStyle.gold.opacity(0),
                                          ChargingStyle.gold.opacity(0.28 * (1 - 0.85 * state.fall))]),
                        startPoint: CGPoint(x: centerX, y: washTop), endPoint: CGPoint(x: centerX, y: bandY)))

        // The line: nearly the island's width while it falls, narrowing once it lands.
        let wide = centerX - 9
        let narrow = size.width * 0.26
        let half = wide - (wide - narrow) * state.settle
        var line = Path()
        line.move(to: CGPoint(x: centerX - half, y: bandY))
        line.addLine(to: CGPoint(x: centerX + half, y: bandY))
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [
                .init(color: ChargingStyle.gold.opacity(0), location: 0),
                .init(color: ChargingStyle.hot.opacity(state.brightness), location: 0.5),
                .init(color: ChargingStyle.gold.opacity(0), location: 1),
            ]),
            startPoint: CGPoint(x: centerX - half, y: bandY), endPoint: CGPoint(x: centerX + half, y: bandY))
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 3))
            layer.stroke(line, with: shading, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
        }
        context.stroke(line, with: shading, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
    }
}

/// Where the sweep is at a moment, each part eased (cubic out).
private struct SweepState {
    /// 0 at the top of the island, 1 landed.
    let fall: Double
    /// 0 landed wide, 1 narrowed.
    let settle: Double
    /// The line's brightness: 1, then breathing between 0.8 and 1 once it has settled.
    let brightness: Double

    init(elapsed: TimeInterval?) {
        guard let elapsed else {
            fall = 1; settle = 1; brightness = 1
            return
        }
        func eased(_ t: Double) -> Double { 1 - pow(1 - min(max(t, 0), 1), 3) }
        fall = eased(elapsed / Motion.Duration.chargeSweep)
        settle = eased((elapsed - Motion.Duration.chargeSweep) / Motion.Duration.chargeSettle)
        let resting = elapsed - Motion.Duration.chargeSweep - Motion.Duration.chargeSettle
        brightness = resting > 0 ? 0.9 + 0.1 * cos(resting * 2 * .pi / Motion.Duration.chargeBreath) : 1
    }
}
