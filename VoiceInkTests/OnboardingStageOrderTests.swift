import XCTest
@testable import VoiceInk

final class OnboardingStageOrderTests: XCTestCase {
    func testIntentPrecedesPermissionsAndShortcutsFollowPermissions() {
        let stages = OnboardingStage.allCases

        let intent = try XCTUnwrap(stages.firstIndex(of: .intent))
        let permissions = try XCTUnwrap(stages.firstIndex(of: .permissions))
        let shortcuts = try XCTUnwrap(stages.firstIndex(of: .shortcuts))

        XCTAssertLessThan(intent, permissions)
        XCTAssertGreaterThan(shortcuts, permissions)
    }
}
