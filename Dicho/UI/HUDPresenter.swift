import AppKit
import SwiftUI

/// Manages the floating HUD `NSPanel` that surfaces recording state and live
/// transcript / notice text.
///
/// Panel floats at `.statusBar` level, spans all Spaces, and ignores mouse
/// events. Visibility is driven by `DictationCoordinator.state` and
/// `activeNotice` via `withObservationTracking`.
///
/// Sizing strategy: the panel is **fixed-size and transparent**; the visible
/// "card" (rounded material background) is drawn by SwiftUI and sized by it
/// alone. This sidesteps the `NSHostingView.fittingSize` / `setContentSize`
/// race that Apple's docs describe for non-Auto-Layout windows — driving the
/// panel size from the hosting view's measurement returned the *previous*
/// content's size, clipping any new Text on first show. With a fixed panel,
/// the card simply grows or shrinks within a stable transparent canvas.
@MainActor
final class HUDPresenter {

    /// Fixed panel size in points. Wide enough to fit ~3 lines of body-size
    /// transcript text plus the longest notice message; tall enough that the
    /// card has room to grow without bumping content off the visible area.
    private static let panelSize = NSSize(width: 600, height: 160)
    /// Distance between the panel's bottom edge and the screen's visible
    /// frame bottom (above Dock / menu bar exclusions).
    private static let bottomMargin: CGFloat = 80

    private let panel: NSPanel

    init(coordinator: DictationCoordinator, settings: AppSettings) {
        let hudView = HUDView(coordinator: coordinator, settings: settings)
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

    private func positionPanel() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - Self.panelSize.width / 2
        let y = screenFrame.minY + Self.bottomMargin
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }
}
