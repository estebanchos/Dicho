import CoreGraphics

/// Pure geometry helper for placing the HUD panel (M11, TASKS.md 11.2).
///
/// Extracted from `HUDPresenter` so the top-center placement math is
/// unit-testable without a live `NSScreen` / `NSPanel`. The presenter supplies
/// the active screen's visible frame; this type has no AppKit dependency.
/// (Multi-display selection is handled natively by `NSScreen.main`.)
enum HUDLayout {

    /// Top-center origin (bottom-left point) for a panel of `panelSize` placed
    /// `topMargin` points below the top of `visibleFrame`.
    static func topCenterOrigin(panelSize: CGSize, in visibleFrame: CGRect, topMargin: CGFloat) -> CGPoint {
        let x = visibleFrame.midX - panelSize.width / 2
        let y = visibleFrame.maxY - topMargin - panelSize.height
        return CGPoint(x: x, y: y)
    }
}
