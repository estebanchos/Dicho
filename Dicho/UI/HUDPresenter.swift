import AppKit
import SwiftUI

/// Manages the floating HUD `NSPanel` that surfaces recording state and volatile text.
///
/// Panel floats at `.statusBar` level, spans all Spaces, and ignores mouse events.
/// Visibility is driven by `DictationCoordinator.state` via `withObservationTracking`.
@MainActor
final class HUDPresenter {

    private let panel: NSPanel
    private let hostingView: NSHostingView<HUDView>

    init(coordinator: DictationCoordinator) {
        let hudView = HUDView(coordinator: coordinator)
        let hosting = NSHostingView(rootView: hudView)
        hosting.sizingOptions = .preferredContentSize
        self.hostingView = hosting

        let panel = NSPanel(
            contentRect: .zero,
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

    /// Recursively re-registers observation so every state, notice, or
    /// transcript change re-evaluates visibility and panel size.
    private func scheduleObservation(coordinator: DictationCoordinator) {
        withObservationTracking {
            // Touch every observable that affects rendered content so the
            // observation fires (and the panel resizes) as the transcript grows.
            _ = coordinator.finalizedTranscript
            _ = coordinator.volatileText
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
        // Show the panel right away with the current (possibly stale) fitting
        // size, then re-position once SwiftUI has laid out the new content.
        // Reading `fittingSize` synchronously inside the observation callback
        // returns the *previous* content's size — deferring fixes both the
        // first-show clipping ("Listening…" cut off after .idle → .recording)
        // and the in-place content swap ("Copied to clipboard — paste manually"
        // clipped when transitioning .inserting → .idle + notice).
        positionPanel()
        panel.orderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.positionPanel()
        }
    }

    private func positionPanel() {
        let panelSize = hostingView.fittingSize
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - panelSize.width / 2
        let y = screenFrame.minY + 80   // 80 pt above dock / bottom edge
        panel.setContentSize(panelSize)
        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }
}
