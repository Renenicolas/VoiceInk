import AppKit
import Foundation

enum StarterModeFactory {
    static let defaultTranscriptionModelName = "parakeet-tdt-0.6b-v3"

    private static let triggerTemplateIds: [StarterModeKind: String] = [
        .email: "email",
        .prompt: "ai",
        .chat: "chat"
    ]

    static func install(
        kinds: [StarterModeKind],
        provider: AIProvider,
        modelName: String?,
        transcriptionModelName: String = defaultTranscriptionModelName,
        isRealtimeTranscriptionEnabled: Bool = true,
        selectedLanguage: String = "auto",
        installedApps: [InstalledAppInfo]? = nil
    ) {
        let manager = ModeManager.shared
        let requestedKinds = Set(kinds)
        let availableInstalledApps = requestedKinds.contains(where: { triggerTemplateIds[$0] != nil })
            ? (installedApps ?? InstalledApps.load())
            : []

        let starterConfigs = StarterModeCatalog.templates
            .filter { requestedKinds.contains($0.kind) }
            .map {
                makeConfig(
                    from: $0,
                    provider: provider,
                    modelName: modelName,
                    transcriptionModelName: transcriptionModelName,
                    isRealtimeTranscriptionEnabled: isRealtimeTranscriptionEnabled,
                    selectedLanguage: selectedLanguage,
                    installedApps: availableInstalledApps
                )
            }

        let nonStarterConfigs = manager.configurations
            .filter { !StarterModeCatalog.ids.contains($0.id) }
            .map { config -> ModeConfig in
                var config = config
                if starterConfigs.contains(where: \.isDefault) {
                    config.isDefault = false
                }
                return config
            }

        manager.replaceConfigurations(starterConfigs + nonStarterConfigs)

        for config in starterConfigs where config.isDefault {
            ShortcutStore.removeShortcutStorage(for: .mode(config.id))
        }

        if let defaultConfig = starterConfigs.first(where: \.isDefault) {
            manager.setActiveConfiguration(defaultConfig)
        }
    }

    /// Web-search-enabled `claude` invocation, used ONLY as the explicit per-mode override
    /// below — never as the default/global template (see LocalCLITemplate.claude, which is
    /// deliberately tools-off so plain dictation cleanup never reaches a network-capable CLI).
    /// No positional prompt arg: stdin already carries it (LocalCLIService.executeCommand).
    static let claudeLiveWebCommandTemplate = "claude -p --allowedTools=WebSearch,WebFetch"

    /// Per-mode CLI command override for seeded starter modes. Modes that benefit from
    /// live web access (prompts destined for other tools, chat, email, assistant Q&A,
    /// live answers) route through `claude` with web tools regardless of the user's global
    /// Local CLI template; the plain transcription-cleanup modes keep using that global
    /// template (tools-off by default).
    static func claudeOverride(for kind: StarterModeKind) -> String? {
        switch kind {
        // Modes whose purpose is live information (Q&A / web answers) get web tools — they
        // produce answers, not the user's own writing, so per-app style memory is intentionally
        // withheld from them (see AIEnhancementService styleMemoryAllowed).
        case .assistant, .liveAnswers:
            return claudeLiveWebCommandTemplate
        // Style-paste modes (prompt-shaping, chat, email) route through tools-off `claude` so the
        // per-app learned-voice memory is allowed to shape them — this is the flagship case
        // (e.g. matching how the user writes emails in a given app) — with no network egress.
        case .prompt, .chat, .email:
            return LocalCLITemplate.claude.commandTemplate
        case .clean, .enhance, .rewrite:
            return nil
        }
    }

    static func isInstalled(kind: StarterModeKind) -> Bool {
        guard let template = StarterModeCatalog.templates.first(where: { $0.kind == kind }) else {
            return false
        }

        return ModeManager.shared.configurations.contains { $0.id == template.id }
    }

    private static func makeConfig(
        from template: StarterModeTemplate,
        provider: AIProvider,
        modelName: String?,
        transcriptionModelName: String,
        isRealtimeTranscriptionEnabled: Bool,
        selectedLanguage: String,
        installedApps: [InstalledAppInfo]
    ) -> ModeConfig {
        ModeConfig(
            id: template.id,
            name: template.name,
            icon: template.icon,
            appConfigs: nil,
            urlConfigs: nil,
            triggerGroups: triggerGroups(for: template.kind, installedApps: installedApps),
            isAIEnhancementEnabled: template.usesAIEnhancement,
            selectedPrompt: template.promptId?.uuidString,
            selectedTranscriptionModelName: transcriptionModelName,
            isRealtimeTranscriptionEnabled: isRealtimeTranscriptionEnabled,
            selectedLanguage: selectedLanguage,
            useClipboardContext: template.kind == .email,
            useSelectedTextContext: template.useSelectedTextContext,
            useScreenCapture: template.useScreenCapture,
            isTextFormattingEnabled: true,
            selectedAIProvider: template.usesAIEnhancement ? provider.rawValue : nil,
            selectedAIModel: template.usesAIEnhancement ? (modelName ?? provider.defaultModel) : nil,
            outputMode: template.outputMode,
            autoSendKey: .none,
            isEnabled: true,
            isDefault: template.isDefault
        )
    }

    private static func triggerGroups(
        for kind: StarterModeKind,
        installedApps: [InstalledAppInfo]
    ) -> [ModeTriggerGroup]? {
        guard let templateId = triggerTemplateIds[kind],
              let template = TriggerTemplateCatalog.templates.first(where: { $0.id == templateId }) else {
            return nil
        }

        let group = template.availableGroup(
            installedApps: installedApps,
            existingAppBundleIds: [],
            existingWebsites: [],
            cleanURL: ModeManager.shared.cleanURL
        )

        return group.isEmpty ? nil : [group]
    }

    /// Appends any starter modes missing from an already-onboarded install (new modes shipped
    /// after the user finished onboarding, or an install that predates the starter catalog
    /// entirely). No-op before onboarding so onboarding owns first setup.
    static func ensureInstalled() {
        let manager = ModeManager.shared
        let onboarded = UserDefaults.standard.bool(forKey: "hasCompletedOnboardingV2")
        guard onboarded || manager.configurations.contains(where: { StarterModeCatalog.ids.contains($0.id) }) else {
            return
        }

        healLocalCLICommandOverrides(manager: manager)

        let existingIds = Set(manager.configurations.map(\.id))
        let missing = StarterModeCatalog.templates.filter { !existingIds.contains($0.id) }
        guard !missing.isEmpty else { return }

        // New AI modes route through the local `claude` CLI (user's Claude subscription, no API
        // key) by default; per-mode provider stays user-editable. Configure the CLI if unset.
        let defaults = UserDefaults.standard
        if (defaults.string(forKey: LocalCLIService.commandTemplateKey) ?? "").isEmpty {
            defaults.set(LocalCLITemplate.claude.commandTemplate, forKey: LocalCLIService.commandTemplateKey)
            defaults.set(LocalCLITemplate.claude.rawValue, forKey: LocalCLIService.selectedTemplateKey)
        }

        let transcriptionReference = manager.configurations.first { $0.selectedTranscriptionModelName != nil }
        let installedApps = missing.contains(where: { triggerTemplateIds[$0.kind] != nil })
            ? InstalledApps.load()
            : []

        for template in missing {
            let config = ModeConfig(
                id: template.id,
                name: template.name,
                icon: template.icon,
                triggerGroups: triggerGroups(for: template.kind, installedApps: installedApps),
                isAIEnhancementEnabled: template.usesAIEnhancement,
                selectedPrompt: template.promptId?.uuidString,
                selectedTranscriptionModelName: transcriptionReference?.selectedTranscriptionModelName ?? defaultTranscriptionModelName,
                isRealtimeTranscriptionEnabled: transcriptionReference?.isRealtimeTranscriptionEnabled ?? true,
                selectedLanguage: transcriptionReference?.selectedLanguage ?? "auto",
                useClipboardContext: template.kind == .email,
                useSelectedTextContext: template.useSelectedTextContext,
                useScreenCapture: template.useScreenCapture,
                isTextFormattingEnabled: true,
                selectedAIProvider: template.usesAIEnhancement ? AIProvider.localCLI.rawValue : nil,
                selectedAIModel: nil,
                outputMode: template.outputMode,
                localCLICommandOverride: template.usesAIEnhancement ? claudeOverride(for: template.kind) : nil,
                isDefault: false
            )
            manager.addConfiguration(config)
        }
    }

    /// Self-heals per-mode Claude routing for installs seeded before `claudeOverride(for:)`
    /// existed: those starter modes have `localCLICommandOverride == nil`, so AI modes
    /// silently fall back to the user's global Local CLI template (e.g. a non-Claude local
    /// binary) and break — Q&A modes like Answers Live can't answer. Brings every installed
    /// starter mode's override in line with `claudeOverride(for:)`, leaving everything else on
    /// the config untouched. Idempotent (no-op once correct). Internal (not private) so it's
    /// directly unit-testable.
    static func healLocalCLICommandOverrides(manager: ModeManager) {
        for config in manager.configurations {
            guard let template = StarterModeCatalog.templates.first(where: { $0.id == config.id }) else { continue }
            let expectedOverride = claudeOverride(for: template.kind)
            guard config.localCLICommandOverride != expectedOverride else { continue }

            var healed = config
            healed.localCLICommandOverride = expectedOverride
            manager.updateConfiguration(healed)
        }
    }

}
