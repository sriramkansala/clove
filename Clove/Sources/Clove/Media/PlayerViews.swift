import SwiftUI

struct ArtworkView: View {
    var image: NSImage?
    var size: CGFloat
    var cornerRadius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct EqualizerView: View {
    var isPlaying: Bool
    var color: Color

    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 2
    private let maxHeight: CGFloat = 14

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(0..<4, id: \.self) { index in
                    let height = barHeight(index: index, time: t)
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth, height: height)
                }
            }
        }
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        guard isPlaying else { return maxHeight * 0.25 }

        let speeds: [Double] = [1.7, 2.3, 1.4, 2.0]
        let phases: [Double] = [0.0, 1.3, 2.6, 4.1]
        let amplitudes: [Double] = [0.35, 0.6, 0.8, 1.0]

        let s = speeds[index % speeds.count]
        let p = phases[index % phases.count]
        let a = amplitudes[index % amplitudes.count]

        // Sine oscillates in [-1, 1]; map to [0.35, 1.0] of max height.
        let wave = (sin(time * s + p) + 1) / 2.0
        let fraction = a * (0.35 + 0.65 * wave)
        return maxHeight * fraction
    }
}

/// A slim scrubber with the times inline at either end. Dragging previews the position and
/// seeks on release; the fill follows the finger directly (manipulation, no tween).
struct ProgressBarView: View {
    @ObservedObject var service: NowPlayingService
    var date: Date

    @State private var dragProgress: CGFloat?

    private let barHeight: CGFloat = 4
    private let timeFont = Font.system(size: 10, weight: .medium).monospacedDigit()

    var body: some View {
        HStack(spacing: 8) {
            Text(timeString(elapsed))
                .font(timeFont)
                .foregroundColor(.white.opacity(0.55))
                .frame(minWidth: 28, alignment: .leading)

            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                    Capsule()
                        .fill(Color.white)
                        .frame(width: width * progress)
                }
                .frame(height: barHeight)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragProgress = max(0, min(1, value.location.x / width))
                        }
                        .onEnded { value in
                            let fraction = max(0, min(1, value.location.x / width))
                            dragProgress = nil
                            if let track = service.track {
                                service.seek(to: fraction * track.duration)
                            }
                        }
                )
            }
            .frame(height: 12)

            Text("-" + timeString(remaining))
                .font(timeFont)
                .foregroundColor(.white.opacity(0.55))
                .frame(minWidth: 32, alignment: .trailing)
        }
    }

    private var elapsed: TimeInterval {
        if let dragProgress, let track = service.track {
            return dragProgress * track.duration
        }
        return service.position(at: date)
    }

    private var remaining: TimeInterval {
        guard let track = service.track else { return 0 }
        return max(0, track.duration - elapsed)
    }

    private var progress: CGFloat {
        if let dragProgress { return dragProgress }
        guard let track = service.track, track.duration > 0 else { return 0 }
        return CGFloat(service.position(at: date) / track.duration)
    }

    private func timeString(_ value: TimeInterval) -> String {
        let total = max(0, Int(value.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The compact player: artwork, title and artist, controls on the same row, scrubber below.
/// Exactly `IslandLayout.playerHeight` tall. Clicking the track opens the app playing it.
struct ExpandedPlayerView: View {
    @ObservedObject var service: NowPlayingService

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button(action: { service.openPlayerApp() }) {
                    HStack(spacing: 10) {
                        ArtworkView(image: service.artwork, size: 36, cornerRadius: 8)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(service.track?.title ?? "")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(.white)
                            Text(service.track?.artist ?? "")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.55))
                        }
                        .lineLimit(1)
                    }
                }
                .buttonStyle(.pressable(.subtle, hoverWash: false))
                .help(service.track.map { "Open \($0.app.displayName)" } ?? "")

                Spacer(minLength: 8)

                HStack(spacing: 16) {
                    control("backward.fill", size: 12) { service.previous() }
                    control(service.isPlaying ? "pause.fill" : "play.fill", size: 16) { service.playPause() }
                        .contentTransition(.symbolEffect(.replace))
                    control("forward.fill", size: 12) { service.next() }
                }
            }
            .frame(height: 36)

            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                ProgressBarView(service: service, date: context.date)
            }
            .frame(height: 16)
        }
        .frame(height: IslandLayout.playerHeight)
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.pressable)
    }
}
