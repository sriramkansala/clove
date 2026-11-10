import AppKit
import SwiftUI

/// Clove's motion vocabulary. Every duration, curve and spring in the app comes from here;
/// a literal `0.3` in a view is how inconsistency spreads.
///
/// The rules:
/// 1. One vocabulary — this file.
/// 2. Transform and opacity only. The island's own frame is the one exception: it is the chrome.
/// 3. Springs for manipulation (presses, toggles, a selection travelling, the island resizing),
///    tweens for transitions (content entering, leaving, changing).
/// 4. Nothing blocking the next action exceeds `Duration.base`.
/// 5. Never animate content while its container moves. Growing: the container moves, content
///    follows in a short subordinate cascade. Shrinking: content leaves in `instant`, then the
///    container moves (`islandShrink` is delayed by exactly that).
/// 6. Correctness never depends on an animation running. With Reduce Motion every change still
///    happens, instantly; numbers always land on their final value.
enum Motion {
    enum Duration {
        /// A cut with a soft edge.
        static let instant: TimeInterval = 0.09
        /// Fades, a focus ring.
        static let fast: TimeInterval = 0.16
        /// The default. Nothing blocking the next action may exceed it.
        static let base: TimeInterval = 0.24
        /// The longest travel.
        static let slow: TimeInterval = 0.38
        /// Hover washes, in and out — slower than base on purpose.
        static let hover: TimeInterval = 0.30
        /// One turn of a busy indicator.
        static let spin: TimeInterval = 1.0

        /// Content morph: the outgoing view leaves faster than the incoming one arrives.
        static let morphOut: TimeInterval = 0.18
        static let morphIn: TimeInterval = 0.25
        /// Cascade: each item's fade, and the gap between items.
        static let cascadeItem: TimeInterval = 0.10
        static let cascadeStagger: TimeInterval = 0.025
        /// The charging moment: the band of light falling through the island, its line narrowing
        /// once it lands, and one breath of the line at rest.
        static let chargeSweep: TimeInterval = 0.75
        static let chargeSettle: TimeInterval = 0.45
        static let chargeBreath: TimeInterval = 1.4
        /// The low-battery notice's one spring.
        static let notice: TimeInterval = 0.6
        /// The low-battery notice: the last bit of charge sends out a ring, then rests.
        static let lowBatteryPulse: TimeInterval = 1.5
        static let lowBatteryPulseRest: TimeInterval = 0.5
    }

    // MARK: Curves

    /// Fast departure, long settle. The default for every tween.
    static func easeOut(_ duration: TimeInterval) -> Animation {
        .timingCurve(0.32, 0.72, 0, 1, duration: duration)
    }

    /// Symmetric, for motion that starts and ends on screen.
    static func easeInOut(_ duration: TimeInterval) -> Animation {
        .timingCurve(0.65, 0, 0.35, 1, duration: duration)
    }

    /// Leaves faster and lands harder: something clicking into place.
    static func snap(_ duration: TimeInterval) -> Animation {
        .timingCurve(0.2, 0.9, 0.25, 1, duration: duration)
    }

    // MARK: Tweens

    static let instant = easeOut(Duration.instant)
    static let fast = easeOut(Duration.fast)
    static let base = easeOut(Duration.base)
    static let slow = easeOut(Duration.slow)
    static let hover = easeOut(Duration.hover)

    /// A live signal (the microphone waveform): linear, because it tracks a level rather than
    /// transitioning between states.
    static let liveSignal = Animation.linear(duration: 0.1)
    /// A pulse that loops while recording (one cycle per `Duration.spin`).
    static let pulse = easeOut(Duration.spin).repeatForever(autoreverses: false)

    // MARK: Springs (mass / stiffness / damping)

    /// Manipulation: presses, toggles, a selection travelling, a level following a key. A trace of overshoot.
    static let snappy = Animation.interpolatingSpring(mass: 0.9, stiffness: 420, damping: 32)
    /// Layout and size, where any overshoot would read as a bounce.
    static let gentle = Animation.interpolatingSpring(mass: 1, stiffness: 260, damping: 34)

    // MARK: The island

    /// The island growing: the container moves now; content cascades in beneath it.
    static let islandGrow = gentle
    /// The island shrinking: content has `instant` to leave before the container moves.
    static let islandShrink = gentle.delay(Duration.instant)
    /// How long a shrink takes to settle: the content's exit plus the container's travel.
    /// Derived, never retyped — e.g. the gap before the next activity is shown.
    static let islandShrinkSettle: TimeInterval = Duration.instant + Duration.slow

    /// The low-battery notice: iOS's island spring (0.6 s, a 0.2 bounce), and every change the
    /// notice goes through runs on it — the island dropping it and taking it back, the hint
    /// changing, the battery turning gold — while each element blurs in or out (`noticeBlur`).
    /// The one place the island is allowed a bounce, and the one place content moves with its
    /// container, because that is the look.
    static let notice = Animation.spring(duration: Duration.notice, bounce: 0.2)

    // MARK: Reduce Motion

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// `withAnimation` that honours Reduce Motion: the change still happens, without motion.
    static func perform(_ animation: Animation, _ changes: () -> Void) {
        withAnimation(reduceMotion ? nil : animation, changes)
    }
}

// MARK: - Transitions

extension AnyTransition {
    /// Content entering while the island grows: a short cascade, subordinate to the container.
    /// `index` orders items top to bottom / left to right. Leaving is a plain `instant` fade.
    static func cascade(_ index: Int, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        let delay = Double(index) * Motion.Duration.cascadeStagger
        let insertion = AnyTransition.opacity
            .combined(with: .offset(y: 4))
            .animation(Motion.easeOut(Motion.Duration.cascadeItem).delay(delay))
        return .asymmetric(insertion: insertion, removal: .opacity.animation(Motion.instant))
    }

    /// A region changing what it shows (player ↔ calendar): scale 0.97 and a 3 pt blur, anchored
    /// at the top centre; out in 180 ms, in in 250 ms. Put both states in a `ZStack` so the incoming
    /// view mounts at once instead of waiting for the outgoing one to leave.
    static func contentMorph(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        let morph = AnyTransition.modifier(active: MorphModifier(shown: 0), identity: MorphModifier(shown: 1))
        return .asymmetric(insertion: morph.animation(Motion.easeOut(Motion.Duration.morphIn)),
                           removal: morph.animation(Motion.easeOut(Motion.Duration.morphOut)))
    }
}

extension AnyTransition {
    /// An element of the low-battery notice arriving out of a 16 pt blur, or leaving into one, on
    /// `Motion.notice`, while the island resizes on the same spring. Put an element's old and new
    /// states in a `ZStack`, so the outgoing one leaves the layout at once and blurs out on top.
    static func noticeBlur(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        return AnyTransition.modifier(active: NoticeBlurModifier(shown: 0), identity: NoticeBlurModifier(shown: 1))
            .animation(Motion.notice)
    }
}

private struct NoticeBlurModifier: ViewModifier {
    /// 0 = hidden, 1 = shown; the spring carries it a little past either end.
    let shown: Double

    func body(content: Content) -> some View {
        content
            .opacity(shown)
            .blur(radius: 16 * max(0, 1 - shown))
    }
}

private struct MorphModifier: ViewModifier {
    /// 0 = hidden, 1 = shown.
    let shown: Double

    func body(content: Content) -> some View {
        content
            .opacity(shown)
            .scaleEffect(0.97 + 0.03 * shown, anchor: .top)
            .blur(radius: 3 * (1 - shown))
    }
}

// MARK: - Pressable

/// The one press response. Large targets sink less than small ones so both read as the same give.
struct PressableButtonStyle: ButtonStyle {
    enum Press {
        /// Rows, tiles, artwork — things tapped often. Sinks to 0.985.
        case subtle
        /// Buttons and small targets. Sinks to 0.97.
        case normal
    }

    var press: Press = .normal
    /// A hover wash behind the label. Off for selected items, which get no hover.
    var hoverWash = true

    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration,
                      pressedScale: press == .subtle ? 0.985 : 0.97,
                      hoverWash: hoverWash)
    }
}

private struct PressableBody: View {
    let configuration: ButtonStyleConfiguration
    let pressedScale: CGFloat
    let hoverWash: Bool

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .background(
                // A minimal rounded rectangle, just outside the label.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(hoverWash && hovering ? 0.10 : 0))
                    .padding(.horizontal, -6)
                    .padding(.vertical, -2)
                    .animation(reduceMotion ? nil : Motion.hover, value: hovering)
            )
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .animation(reduceMotion ? nil : Motion.snappy, value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// `.buttonStyle(.pressable)` — buttons and small targets.
    static var pressable: PressableButtonStyle { PressableButtonStyle() }

    static func pressable(_ press: PressableButtonStyle.Press, hoverWash: Bool = true) -> PressableButtonStyle {
        PressableButtonStyle(press: press, hoverWash: hoverWash)
    }
}
