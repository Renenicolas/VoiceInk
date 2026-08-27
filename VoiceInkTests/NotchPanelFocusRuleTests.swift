import Testing
@testable import VoiceInk

struct NotchPanelFocusRuleTests {
    @Test func onlyAssistantStateWantsKeyFocus() {
        #expect(NotchPanelDisplayState.assistant.wantsKeyFocus)
        #expect(!NotchPanelDisplayState.collapsed.wantsKeyFocus)
        #expect(!NotchPanelDisplayState.active.wantsKeyFocus)
        #expect(!NotchPanelDisplayState.liveText.wantsKeyFocus)
    }
}
