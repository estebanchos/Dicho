import AppKit
import ApplicationServices
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
/// menu-bar item. The active screen is the one holding the frontmost app's
/// focused window (via Accessibility), falling back to the screen under the
/// mouse, then the primary display. All placement math lives in the pure,
/// unit-tested `HUDLayout`.
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

    /// Positions the panel top-center on the active screen. Screen selection
    /// and geometry are delegated to `HUDLayout`; this method only gathers the
    /// live AppKit inputs (screen frames, reference point).
    private func positionPanel() {
        let screens = NSScreen.screens.map {
            HUDLayout.ScreenLayout(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        guard let origin = HUDLayout.panelOrigin(
            referencePoint: activeReferencePoint(),
            screens: screens,
            panelSize: Self.panelSize,
            topMargin: Self.topMargin
        ) else { return }
        panel.setFrameOrigin(origin)
    }

    /// A point identifying the screen the user is working on: the center of the
    /// frontmost app's focused window (Accessibility), else the mouse location.
    /// Both are returned in Cocoa global coordinates.
    private func activeReferencePoint() -> CGPoint? {
        frontmostFocusedWindowCenter() ?? NSEvent.mouseLocation
    }

    /// Center of the frontmost application's focused window, converted from
    /// Accessibility (top-left origin) to Cocoa (bottom-left origin) global
    /// coordinates. Returns nil when Accessibility is untrusted or the window
    /// geometry can't be read — callers fall back to the mouse location.
    private func frontmostFocusedWindowCenter() -> CGPoint? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let window = windowRef as! AXUIElement

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              let posRef, CFGetTypeID(posRef) == AXValueGetTypeID(),
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }

        let axCenter = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        return HUDLayout.cocoaPoint(fromAXPoint: axCenter, primaryHeight: primaryHeight)
    }
}
