import CoreGraphics
import Testing
@testable import Dicho

/// Pure geometry for the M11 HUD placement (TASKS.md 11.2): top-center within
/// the active screen's visible frame. No NSScreen / NSPanel — plain rect math.
@Suite("HUDLayout — top-center placement (M11)")
struct HUDLayoutTests {

    private let panelSize = CGSize(width: 600, height: 200)

    @Test("Top-center origin centers horizontally and sits below the visible top edge")
    func topCenterOriginGeometry() {
        // Primary screen, menu bar excluded from visibleFrame.
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let origin = HUDLayout.topCenterOrigin(panelSize: panelSize, in: visible, topMargin: 24)

        #expect(origin.x == visible.midX - panelSize.width / 2)   // 720 - 300 = 420
        // Panel's top edge is 24 pt below the visible top; y is its bottom-left.
        #expect(origin.y == visible.maxY - 24 - panelSize.height) // 875 - 24 - 200 = 651
    }

    @Test("Origin respects a non-zero visibleFrame origin (secondary display)")
    func topCenterOriginOffsetScreen() {
        let visible = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let origin = HUDLayout.topCenterOrigin(panelSize: panelSize, in: visible, topMargin: 24)

        #expect(origin.x == visible.midX - panelSize.width / 2)
        #expect(origin.y == visible.maxY - 24 - panelSize.height)
    }
}
