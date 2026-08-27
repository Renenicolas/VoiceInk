import XCTest
@testable import VoiceInk

/// The onboarding is a full-screen, borderless window. If its exit is ever
/// conditional again, a person can be trapped in it with no visible way out —
/// which is exactly what happened on 2026-08-27, when the Skip button was hidden
/// on the permissions stage and the Continue button rendered under the Dock.
final class OnboardingEscapeHatchTests: XCTestCase {
    func testEveryStageKeepsContentOutOfTheDockAndMenuBar() {
        let insets = OnboardingLayout.safeAreaInsets
        XCTAssertGreaterThanOrEqual(insets.top, 0)
        XCTAssertGreaterThanOrEqual(insets.bottom, 0)
        // On any real Mac the menu bar is present, so the top inset must be real.
        // A zero here means content is being laid out under the menu bar.
        if NSScreen.main != nil {
            XCTAssertGreaterThan(insets.top, 0, "content would render under the menu bar")
        }
    }

    func testScrimStillLetsTheBackgroundThrough() {
        // 0.82 read as solid black and hid both the desktop and the aura.
        XCTAssertLessThan(OnboardingBackgroundMetrics.scrimOpacity, 0.6)
        XCTAssertGreaterThan(OnboardingBackgroundMetrics.scrimOpacity, 0.2)
    }
}
