import CoreGraphics

/// Sizes of the expanded island. The model sizes the island from these and the views lay out
/// to them, so the black shape always hugs its content.
///
/// Expanded layout: the notch row (tabs left of the camera, gear right of it), then one page
/// of content below it.
enum IslandLayout {
    static let expandedWidth: CGFloat = 400
    /// Minimum width of each side of the notch row when expanded: room for up to four page tabs
    /// on the left and the mic and gear on the right, none of them under the camera.
    static let minimumExpandedWing: CGFloat = 110

    static let horizontalPadding: CGFloat = 16
    /// Inside a page tab; the notch row is inset by this much less, so tab icons line up with
    /// the page content below them.
    static let tabPadding: CGFloat = 4
    static let contentTopPadding: CGFloat = 6
    static let contentBottomPadding: CGFloat = 16

    /// Width of the island during a voice note.
    static let voiceWidth: CGFloat = 560

    static let expandedTopRadius: CGFloat = 14
    static let expandedBottomRadius: CGFloat = 24

    // Page heights
    static let playerHeight: CGFloat = 60
    /// One line of text: "Nothing playing", "No more events", "Show calendar".
    static let messageHeight: CGFloat = 24
    static let eventRowHeight: CGFloat = 28
    static let eventRowSpacing: CGFloat = 8
    static let maxEvents = 2

    // System page: a battery tile above CPU and memory tiles, then a line of smaller figures.
    static let systemTileRadius: CGFloat = 12
    static let systemTilePadding: CGFloat = 10
    static let systemTileGap: CGFloat = 8
    static let systemBatteryTileHeight: CGFloat = 50
    static let systemTileHeaderHeight: CGFloat = 14
    static let systemTileHeaderGap: CGFloat = 5
    static let systemTileBodyHeight: CGFloat = 26
    static let systemTileHeight: CGFloat = 8 + systemTileHeaderHeight + systemTileHeaderGap + systemTileBodyHeight + 8
    /// The per-core bars, standing on the CPU figure's baseline.
    static let systemMeterHeight: CGFloat = 19
    /// The memory bar.
    static let systemBarHeight: CGFloat = 7
    static let systemFooterGap: CGFloat = 9
    static let systemFooterHeight: CGFloat = 13

    static func systemPageHeight(hasBattery: Bool) -> CGFloat {
        (hasBattery ? systemBatteryTileHeight + systemTileGap : 0) + systemTileHeight + systemFooterGap + systemFooterHeight
    }

    /// Each wing of every popup beside the notch (charging, low battery, volume, a device, a
    /// deadline, a meeting): one width for all, the open island's, so hovering a popup only grows
    /// it downward. Now playing, which stays rather than pops up, keeps its narrow pill.
    static let activityWing: CGFloat = minimumExpandedWing

    // Low-battery notice, below the camera: the level over a hint on the left, the battery in a
    // pill on the right. iOS's proportions at about 0.83 scale, a Mac point being larger.
    static let noticePillSize = CGSize(width: 63, height: 38)
    /// Between the pill and the island's right and bottom edges.
    static let noticeInset: CGFloat = 10
    static let noticeLeading: CGFloat = 22
    static let noticeTopGap: CGFloat = 4
    static let noticeStageHeight: CGFloat = noticeTopGap + noticePillSize.height + noticeInset

    // Tasks page: issues grouped under their workflow state, as in Linear's "My issues".
    static let taskRowHeight: CGFloat = 18
    static let taskHeaderHeight: CGFloat = 14
    static let taskRowSpacing: CGFloat = 5
    static let taskGroupSpacing: CGFloat = 8
    /// Rows shown before "View more" (each state heading counts as a row).
    static let compactTaskRows = 5
    /// Tallest the list grows after "View more"; beyond this it scrolls.
    static let expandedTasksMaxHeight: CGFloat = 170

    /// Height of `rows` list rows (calendar and tasks share one row size), or one message line.
    static func listHeight(rows: Int) -> CGFloat {
        guard rows > 0 else { return messageHeight }
        return CGFloat(rows) * eventRowHeight + CGFloat(rows - 1) * eventRowSpacing
    }

    static func calendarHeight(events: Int) -> CGFloat {
        listHeight(rows: min(events, maxEvents))
    }
}
