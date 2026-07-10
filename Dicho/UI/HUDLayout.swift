import CoreGraphics

/// Pure geometry helpers for placing the HUD panel (M11, TASKS.md 11.2).
///
/// Extracted from `HUDPresenter` so the placement math — top-center origin,
/// multi-display screen selection, and Accessibility→Cocoa coordinate
/// conversion — is unit-testable without a live `NSScreen` / `NSPanel`. The
/// presenter supplies the real screen geometry and reference point; this type
/// contains no AppKit dependency.
enum HUDLayout {

    /// A screen's geometry in Cocoa global coordinates (bottom-left origin).
    /// `frame` is the full display; `visibleFrame` excludes the menu bar / Dock.
    struct ScreenLayout: Equatable {
        let frame: CGRect
        let visibleFrame: CGRect
    }

    /// Top-center origin (bottom-left point) for a panel of `panelSize` placed
    /// `topMargin` points below the top of `visibleFrame`.
    static func topCenterOrigin(panelSize: CGSize, in visibleFrame: CGRect, topMargin: CGFloat) -> CGPoint {
        let x = visibleFrame.midX - panelSize.width / 2
        let y = visibleFrame.maxY - topMargin - panelSize.height
        return CGPoint(x: x, y: y)
    }

    /// Top-center origin on the screen the user is working on. Picks the screen
    /// whose full frame contains `referencePoint` (the frontmost app's focused
    /// window, or the mouse); falls back to the first screen (the primary /
    /// menu-bar display) when the point is nil or off every screen. Returns nil
    /// only when there are no screens.
    static func panelOrigin(
        referencePoint: CGPoint?,
        screens: [ScreenLayout],
        panelSize: CGSize,
        topMargin: CGFloat
    ) -> CGPoint? {
        guard let chosen = chosenScreen(referencePoint: referencePoint, screens: screens) else { return nil }
        return topCenterOrigin(panelSize: panelSize, in: chosen.visibleFrame, topMargin: topMargin)
    }

    /// The screen whose full frame contains `referencePoint`, else the first
    /// screen, else nil when `screens` is empty.
    static func chosenScreen(referencePoint: CGPoint?, screens: [ScreenLayout]) -> ScreenLayout? {
        if let point = referencePoint, let match = screens.first(where: { $0.frame.contains(point) }) {
            return match
        }
        return screens.first
    }

    /// Converts an Accessibility point (top-left origin, y increasing downward,
    /// relative to the primary display's top-left) to a Cocoa global point
    /// (bottom-left origin). `primaryHeight` is the height of the primary
    /// screen — the one whose frame origin is `(0, 0)`.
    static func cocoaPoint(fromAXPoint axPoint: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: axPoint.x, y: primaryHeight - axPoint.y)
    }
}
