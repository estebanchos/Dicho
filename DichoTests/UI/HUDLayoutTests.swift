import CoreGraphics
import Testing
@testable import Dicho

/// Pure geometry for the M11 HUD placement (TASKS.md 11.2): top-center on the
/// screen the user is working on, with multi-display selection driven by a
/// reference point. No NSScreen / NSPanel — plain rect math.
@Suite("HUDLayout — top-center placement + multi-display selection (M11)")
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

    @Test("Panel origin picks the screen containing the reference point")
    func panelOriginSelectsScreenUnderReference() {
        let primary = HUDLayout.ScreenLayout(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
        let secondary = HUDLayout.ScreenLayout(
            frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055))

        // Reference point sits on the secondary display.
        let origin = HUDLayout.panelOrigin(
            referencePoint: CGPoint(x: 2000, y: 500),
            screens: [primary, secondary],
            panelSize: panelSize,
            topMargin: 24)

        #expect(origin == HUDLayout.topCenterOrigin(
            panelSize: panelSize, in: secondary.visibleFrame, topMargin: 24))
    }

    @Test("Panel origin falls back to the first screen when the reference is off every screen")
    func panelOriginFallsBackToFirstScreen() {
        let primary = HUDLayout.ScreenLayout(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
        let secondary = HUDLayout.ScreenLayout(
            frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055))

        let offscreen = HUDLayout.panelOrigin(
            referencePoint: CGPoint(x: -9999, y: -9999),
            screens: [primary, secondary],
            panelSize: panelSize,
            topMargin: 24)
        let nilReference = HUDLayout.panelOrigin(
            referencePoint: nil,
            screens: [primary, secondary],
            panelSize: panelSize,
            topMargin: 24)
        let expected = HUDLayout.topCenterOrigin(
            panelSize: panelSize, in: primary.visibleFrame, topMargin: 24)

        #expect(offscreen == expected)
        #expect(nilReference == expected)
    }

    @Test("Panel origin is nil when there are no screens")
    func panelOriginNoScreens() {
        #expect(HUDLayout.panelOrigin(
            referencePoint: CGPoint(x: 10, y: 10),
            screens: [],
            panelSize: panelSize,
            topMargin: 24) == nil)
    }

    @Test("AX point converts to Cocoa coordinates by flipping y about the primary height")
    func cocoaPointFlipsY() {
        // AX origin is top-left, y grows downward; Cocoa origin is bottom-left.
        let cocoa = HUDLayout.cocoaPoint(fromAXPoint: CGPoint(x: 300, y: 100), primaryHeight: 900)
        #expect(cocoa == CGPoint(x: 300, y: 800))
    }
}
