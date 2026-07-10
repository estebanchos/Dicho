import AppKit
import SwiftUI

/// Manages the floating HUD `NSPanel` that surfaces recording state and live
/// transcript / notice text.
///
/// Panel floats at `.statusBar` level, spans all Spaces, and ignores mouse
/// events. Visibility is driven by `DictationCoordinator.state` and
/// `activeNotice` via `withObservationTracking`.
///
/// Placement (M11): **top-center** of the screen the user is working on —
/// macOS trains attention to the top of the screen and it sits next to the
/// menu-bar item. The active screen is `NSScreen.main` — documented as the
/// screen holding the window with keyboard focus, i.e. the frontmost app's
/// screen — which handles multi-display natively. The top-center geometry
/// lives in the pure, unit-tested `HUDLayout`.
///
/// Sizing strategy: the panel is **fixed-size and transparent**; the visible
/// "card" (rounded material background) is drawn by SwiftUI and sized by it
/// alone. This sidesteps the `NSHostingView.fittingSize` / `setContentSize`
/// race that Apple's docs describe for non-Auto-Layout windows — driving the
/// panel size from the hosting view's measurement returned the *previous*
/// content's size, clipping any new Text on first show. With a fixed panel,
/// the card simply grows or shrinks within a stable transparent canvas,
/// top-anchored so it drops down from just below the screen's top edge.
@MainActor
final class HUDPresenter {

    /// Fixed panel size in points. Wide enough to fit the live transcript plus
    /// the recording glyph and RAW badge; tall enough that the card (which
    /// includes the scrolling transcript region) has room to grow downward
    /// from the top edge without clipping.
    private static let panelSize = NSSize(width: 600, height: 240)
    /// Distance between the panel's top edge and the top of the active
    /// screen's visible frame (below the menu bar).
    private static let topMargin: CGFloat = 12

    private let panel: NSPanel

    init(coordinator: DictationCoordinator, settings: AppSettings) {
        // Pin the SwiftUI root to a concrete panel-sized frame. The card centers
        // via `.frame(maxWidth: .infinity)`, which only fills/centers when a
        // definite width is proposed; NSHostingView(sizingOptions: []) proposes
        // an unspecified width, so without this the card collapses to its
        // content width and lands at the leading edge (M11 off-center bug).
        let hudView = HUDView(coordinator: coordinator, settings: settings)
            .frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .top)
        let hosting = NSHostingView(rootView: hudView)
        // No Auto Layout constraints — we manage the panel size statically.
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: Self.panelSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false     // drop shadow drawn by SwiftUI
        panel.ignoresMouseEvents = true
        panel.contentView = hosting
        self.panel = panel

        scheduleObservation(coordinator: coordinator)
    }

    // MARK: - Private

    /// Recursively re-registers observation so every state or notice change
    /// re-evaluates visibility. Transcript reads are not needed in the
    /// observation body now that the panel does not resize with content.
    private func scheduleObservation(coordinator: DictationCoordinator) {
        withObservationTracking {
            updateVisibility(state: coordinator.state, notice: coordinator.activeNotice)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.scheduleObservation(coordinator: coordinator)
            }
        }
    }

    private func updateVisibility(state: DictationState, notice: DictationNotice?) {
        if state == .idle && notice == nil {
            panel.orderOut(nil)
            return
        }
        positionPanel()
        panel.orderFront(nil)
    }

    /// Positions the panel top-center on `NSScreen.main` (the screen with
    /// keyboard focus = the frontmost app's screen). Geometry is delegated to
    /// the pure, unit-tested `HUDLayout`.
    private func positionPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let origin = HUDLayout.topCenterOrigin(
            panelSize: Self.panelSize,
            in: screen.visibleFrame,
            topMargin: Self.topMargin)
        panel.setFrameOrigin(origin)
        #if DEBUG
        // Placement diagnostics only — never prints dictated content. Helps
        // confirm the chosen screen / origin if the HUD ever looks off-center.
        print("[DEBUG] HUD positioned: visibleFrame=\(screen.visibleFrame) origin=\(origin)")
        #endif
    }
}
