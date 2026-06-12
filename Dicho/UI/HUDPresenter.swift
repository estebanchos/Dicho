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

    /// Recursively re-registers observation so every state change re-evaluates visibility.
    private func scheduleObservation(coordinator: DictationCoordinator) {
        withObservationTracking {
            updateVisibility(coordinator.state)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.scheduleObservation(coordinator: coordinator)
            }
        }
    }

    private func updateVisibility(_ state: DictationState) {
        if state == .idle {
            panel.orderOut(nil)
        } else {
            positionPanel()
            panel.orderFront(nil)
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
