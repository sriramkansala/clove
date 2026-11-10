import AppKit

enum NotchGeometry {
    static func targetScreen() -> NSScreen? {
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return screen
        }
        return NSScreen.main
    }

    static func notchSize(on screen: NSScreen) -> CGSize {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = max(0, screen.frame.width - left.width - right.width)
            return CGSize(width: width, height: screen.safeAreaInsets.top)
        } else {
            let height = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
            return CGSize(width: 200, height: height)
        }
    }

    static func notchRect(on screen: NSScreen) -> CGRect {
        let size = notchSize(on: screen)
        return CGRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}
