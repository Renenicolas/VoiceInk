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

    /// The default/global `claude` template is deliberately tools-off (H1): plain
    /// clean/enhance/rewrite dictation, and any user who picks "Claude" from the template
    /// picker for everyday use, must never reach a network-capable CLI by default.
    @Test func claudeCLITemplateHasNoNetworkTools() {
        #expect(!LocalCLITemplate.claude.commandTemplate.contains("--allowedTools"))
    }

    @Test func liveInfoModesGetWebToolsAndNoStyleMemory() {
        // Q&A / web-answer modes get web tools; style memory is withheld from them by design.
        let webKinds: Set<StarterModeKind> = [.assistant, .liveAnswers]
        for kind in webKinds {
            #expect(
                StarterModeFactory.claudeOverride(for: kind) == StarterModeFactory.claudeLiveWebCommandTemplate,
                "\(kind) should route through the web-search-enabled claude CLI override"
            )
            #expect(
                StarterModeFactory.claudeOverride(for: kind)?.contains("--allowedTools=WebSearch,WebFetch") == true,
                "\(kind) should have web search tools enabled"
            )
        }
    }

    @Test func stylePasteModesUseToolsOffClaudeSoStyleMemoryApplies() {
        // prompt/chat/email route through tools-off `claude` (no web egress) so per-app learned
        // style memory is allowed to shape them — and must NOT carry web tools.
        let styleKinds: Set<StarterModeKind> = [.prompt, .chat, .email]
        for kind in styleKinds {
            #expect(
                StarterModeFactory.claudeOverride(for: kind) == LocalCLITemplate.claude.commandTemplate,
                "\(kind) should route through tools-off claude so style memory applies"
            )
            #expect(
                StarterModeFactory.claudeOverride(for: kind)?.contains("--allowedTools") == false,
                "\(kind) must not have web tools (style memory would be withheld)"
            )
        }
    }

    @Test func seededCleanupModesKeepTheGlobalTemplate() {
        let globalTemplateKinds: Set<StarterModeKind> = [.clean, .enhance, .rewrite]
        for kind in globalTemplateKinds {
            #expect(
                StarterModeFactory.claudeOverride(for: kind) == nil,
                "\(kind) should keep using the user's global Local CLI template"
            )
        }
    }
}
