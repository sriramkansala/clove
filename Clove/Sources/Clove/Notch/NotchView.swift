import SwiftUI

/// Root view inside the notch panel. Motion is driven by the model (`Motion.perform`); this view
/// only declares how content enters and leaves (`Motion.swift` transitions), never its own timing.
struct NotchView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var nowPlaying: NowPlayingService

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            island
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var island: some View {
        ZStack(alignment: .top) {
            // Always mounted; its parts enter and leave with the expanded state.
            ExpandedContent(model: model, nowPlaying: nowPlaying, calendar: model.calendar,
                            linear: model.linear)

            if model.state == .collapsed {
                if let activity = model.activities.current {
                    TransientActivityView(activity: activity,
                                          notchSize: model.notchSize,
                                          wingWidth: model.activities.wingWidth,
                                          meterHeight: model.activities.meterHeight,
                                          onRequestLowPowerMode: model.requestLowPowerMode)
                        .id(activity.id)
                        .transition(activity.kind.isNotice ? .noticeBlur(reduceMotion: reduceMotion)
                                                           : .cascade(0, reduceMotion: reduceMotion))
                } else if model.showsMeetingActivity, let meeting = model.calendar.imminentMeeting {
                    MeetingSoonView(meeting: meeting, notchSize: model.notchSize)
                        .id(meeting.id)
                        .transition(.cascade(0, reduceMotion: reduceMotion))
                } else if model.showsMusicActivity {
                    CollapsedMusicContent(model: model, nowPlaying: nowPlaying)
                        .transition(.cascade(0, reduceMotion: reduceMotion))
                }
            }
        }
        .frame(width: model.islandSize.width, height: model.islandSize.height, alignment: .top)
        .frame(width: model.islandSize.width + 2 * model.topRadius, height: model.islandSize.height)
        .background(NotchShape(topRadius: model.topRadius, bottomRadius: model.bottomRadius).fill(Color.black))
        .clipShape(NotchShape(topRadius: model.topRadius, bottomRadius: model.bottomRadius))
        .shadow(color: .black.opacity(model.state == .expanded ? 0.35 : 0), radius: 10, y: 4)
    }

    private struct CollapsedMusicContent: View {
        @ObservedObject var model: NotchViewModel
        @ObservedObject var nowPlaying: NowPlayingService

        var body: some View {
            HStack(spacing: 0) {
                ArtworkView(image: nowPlaying.artwork, size: 22, cornerRadius: 6)
                    .frame(width: model.compactWing, height: model.notchSize.height)

                Color.clear
                    .frame(width: model.notchSize.width, height: model.notchSize.height)

                EqualizerView(isPlaying: nowPlaying.isPlaying, color: nowPlaying.accentColor)
                    .frame(width: model.compactWing, height: model.notchSize.height)
            }
        }
    }

    private struct ExpandedContent: View {
        @ObservedObject var model: NotchViewModel
        @ObservedObject var nowPlaying: NowPlayingService
        @ObservedObject var calendar: CalendarService
        @ObservedObject var linear: LinearService

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Namespace private var pageNamespace

        var body: some View {
            VStack(spacing: 0) {
                if model.state == .expanded && model.voiceActive {
                    // A voice note fills the island below the camera, in place of the pages.
                    Color.clear.frame(height: model.notchSize.height)
                    VoiceIslandView(controller: model.voice, onHeightChange: model.setVoiceHeight)
                        .environment(\.colorScheme, .dark)
                        .transition(.cascade(1, reduceMotion: reduceMotion))
                } else if model.state == .expanded {
                    notchRow
                        .transition(.cascade(0, reduceMotion: reduceMotion))
                    page
                        .frame(height: model.expandedContentHeight, alignment: .top)
                        .padding(.horizontal, IslandLayout.horizontalPadding)
                        .padding(.top, IslandLayout.contentTopPadding)
                        .transition(.cascade(1, reduceMotion: reduceMotion))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }

        /// The row level with the camera: tabs to its left, the gear to its right, nothing under it.
        private var notchRow: some View {
            HStack(spacing: 0) {
                if model.showsPageTabs {
                    HStack(spacing: 2) {
                        ForEach(model.availablePages, id: \.self) { page in
                            PageTab(symbol: Self.symbol(for: page), page: page, model: model,
                                    namespace: pageNamespace)
                        }
                    }
                    .transition(.opacity.animation(reduceMotion ? nil : Motion.fast))
                }
                Spacer(minLength: model.notchSize.width)
                HStack(spacing: 14) {
                    if model.linear.isConnected {
                        Button(action: { model.toggleVoice() }) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .buttonStyle(.pressable)
                        .help("Record a voice note for Linear")
                    }
                    Button(action: { model.openSettings() }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.leading, IslandLayout.horizontalPadding - IslandLayout.tabPadding)
            .padding(.trailing, IslandLayout.horizontalPadding)
            .frame(height: model.notchSize.height)
        }

        /// One page at a time. Both branches live in a ZStack so the incoming page mounts at
        /// once and the two overlap under the morph's blur instead of waiting on each other.
        private var page: some View {
            ZStack(alignment: .top) {
                if model.visiblePage == .calendar {
                    CalendarColumnView(calendar: calendar)
                        .transition(.contentMorph(reduceMotion: reduceMotion))
                } else if model.visiblePage == .tasks {
                    TasksView(linear: linear, expanded: model.tasksExpanded, onViewMore: model.showMoreTasks)
                        .transition(.contentMorph(reduceMotion: reduceMotion))
                } else if model.visiblePage == .system {
                    SystemPageView(system: model.system)
                        .transition(.contentMorph(reduceMotion: reduceMotion))
                } else if nowPlaying.track != nil {
                    ExpandedPlayerView(service: nowPlaying)
                        .transition(.contentMorph(reduceMotion: reduceMotion))
                } else {
                    MessageView(symbol: "music.note", text: "Nothing playing")
                        .transition(.contentMorph(reduceMotion: reduceMotion))
                }
            }
            .frame(maxWidth: .infinity)
        }

        private static func symbol(for page: NotchViewModel.ExpandedPage) -> String {
            switch page {
            case .player: return "music.note"
            case .calendar: return "calendar"
            case .tasks: return "checklist"
            case .system: return "gauge.with.dots.needle.50percent"
            }
        }
    }

    /// A notch-row page button. The selection is one pill that travels between tabs
    /// (`matchedGeometryEffect`, moved by the model on `Motion.snappy`), not two fills cross-fading.
    private struct PageTab: View {
        let symbol: String
        let page: NotchViewModel.ExpandedPage
        @ObservedObject var model: NotchViewModel
        let namespace: Namespace.ID

        private var isSelected: Bool { model.visiblePage == page }

        var body: some View {
            Button(action: { model.show(page) }) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.45))
                    .padding(.horizontal, IslandLayout.tabPadding)
                    .padding(.vertical, 3)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.14))
                                .matchedGeometryEffect(id: "pageSelection", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
            }
            // Selected items get no hover wash.
            .buttonStyle(.pressable(.normal, hoverWash: !isSelected))
        }
    }
}
