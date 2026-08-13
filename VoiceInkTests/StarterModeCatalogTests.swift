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

    /// Regression test for the shipped self-heal bug: modes seeded before `claudeOverride`
    /// existed have `localCLICommandOverride == nil`, so AI modes silently fell back to the
    /// user's global Local CLI template and broke (e.g. Answers Live couldn't do Q&A).
    /// `healLocalCLICommandOverrides` must bring every installed starter mode's override back
    /// in line with `claudeOverride(for:)`.
    @Test @MainActor func healLocalCLICommandOverridesFixesExistingStarterModes() {
        let manager = ModeManager.shared
        let originalConfigurations = manager.configurations
        defer { manager.replaceConfigurations(originalConfigurations) }

        func seededConfig(for kind: StarterModeKind, override: String?) -> ModeConfig {
            let template = StarterModeCatalog.templates.first { $0.kind == kind }!
            return ModeConfig(
                id: template.id,
                name: template.name,
                isAIEnhancementEnabled: template.usesAIEnhancement,
                localCLICommandOverride: override
            )
        }

        // Mimic a pre-claudeOverride install: AI modes seeded with nil, one with a stale value.
        manager.replaceConfigurations([
            seededConfig(for: .clean, override: nil),
            seededConfig(for: .enhance, override: nil),
            seededConfig(for: .rewrite, override: nil),
            seededConfig(for: .assistant, override: nil),
            seededConfig(for: .liveAnswers, override: "stale-template"),
            seededConfig(for: .prompt, override: nil),
            seededConfig(for: .chat, override: nil),
            seededConfig(for: .email, override: nil),
        ])

        StarterModeFactory.healLocalCLICommandOverrides(manager: manager)

        func override(for kind: StarterModeKind) -> String? {
            let template = StarterModeCatalog.templates.first { $0.kind == kind }!
            return manager.configurations.first { $0.id == template.id }?.localCLICommandOverride
        }

        let webKinds: Set<StarterModeKind> = [.assistant, .liveAnswers]
        for kind in webKinds {
            #expect(override(for: kind) == StarterModeFactory.claudeLiveWebCommandTemplate)
        }

        let stylePasteKinds: Set<StarterModeKind> = [.chat, .email, .prompt]
        for kind in stylePasteKinds {
            #expect(override(for: kind) == LocalCLITemplate.claude.commandTemplate)
        }

        let globalTemplateKinds: Set<StarterModeKind> = [.clean, .enhance, .rewrite]
        for kind in globalTemplateKinds {
            #expect(override(for: kind) == nil)
        }

        // Idempotent: running again makes no further changes to any override.
        let overridesAfterFirstHeal = StarterModeKind.allCases.map { override(for: $0) }
        StarterModeFactory.healLocalCLICommandOverrides(manager: manager)
        let overridesAfterSecondHeal = StarterModeKind.allCases.map { override(for: $0) }
        #expect(overridesAfterFirstHeal == overridesAfterSecondHeal)
    }
}
