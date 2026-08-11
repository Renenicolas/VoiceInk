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
    /// after the user finished onboarding). No-op before onboarding so onboarding owns first setup.
    static func ensureInstalled() {
        let manager = ModeManager.shared
        guard manager.configurations.contains(where: { StarterModeCatalog.ids.contains($0.id) }) else {
            return
        }

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
                isDefault: false
            )
            manager.addConfiguration(config)
        }
    }

}
