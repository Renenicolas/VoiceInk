import Testing
import Foundation
@testable import VoiceInk

struct StarterModeCatalogTests {

    @Test func everyStarterModePromptIsSeeded() {
        let seededIds = Set(PromptTemplates.seedPrompts.map(\.id))
        for template in StarterModeCatalog.templates where template.usesAIEnhancement {
            #expect(template.promptId != nil, "\(template.name) uses AI enhancement but has no prompt")
            if let promptId = template.promptId {
                #expect(seededIds.contains(promptId), "\(template.name)'s prompt is missing from PromptTemplates")
            }
        }
    }

    @Test func starterModeAndPromptIdsAreUnique() {
        let modeIds = StarterModeCatalog.templates.map(\.id)
        #expect(Set(modeIds).count == modeIds.count)

        let promptIds = PromptTemplates.seedPrompts.map(\.id)
        #expect(Set(promptIds).count == promptIds.count)
    }

    @Test func everyStarterModeKindHasOneTemplate() {
        for kind in StarterModeKind.allCases {
            #expect(StarterModeCatalog.templates.filter { $0.kind == kind }.count == 1)
        }
    }

    @Test func starterModeTriggerTemplatesExist() {
        #expect(TriggerTemplateCatalog.templates.contains { $0.id == "ai" })
        #expect(TriggerTemplateCatalog.templates.contains { $0.id == "email" })
        #expect(TriggerTemplateCatalog.templates.contains { $0.id == "chat" })
    }

    @Test func claudeCLITemplateAllowsWebSearch() {
        #expect(LocalCLITemplate.claude.commandTemplate.contains("--allowedTools=WebSearch,WebFetch"))
    }
}
