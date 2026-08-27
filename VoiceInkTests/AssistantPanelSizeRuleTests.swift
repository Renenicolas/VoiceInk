import Testing
@testable import VoiceInk

struct AssistantPanelSizeRuleTests {
    @Test func askingAndAnsweringSizes() {
        #expect(AssistantPanelSizeRule.isAnswering(messageCount: 0, isBusy: false) == false)
        #expect(AssistantPanelSizeRule.isAnswering(messageCount: 1, isBusy: false) == true)
    }
}
