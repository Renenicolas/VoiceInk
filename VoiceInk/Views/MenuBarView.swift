import SwiftUI
import LaunchAtLogin

struct MenuBarView: View {
    @EnvironmentObject var engine: VoiceInkEngine
    @EnvironmentObject var recorderUIManager: RecorderUIManager
    @EnvironmentObject var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject var whisperModelManager: WhisperModelManager
    @EnvironmentObject var recordingShortcutManager: RecordingShortcutManager
    @EnvironmentObject var menuBarManager: MenuBarManager
    @EnvironmentObject var updaterViewModel: UpdaterViewModel
    @EnvironmentObject var updateCheckService: UpdateCheckService
    @EnvironmentObject var enhancementService: AIEnhancementService
    @EnvironmentObject var aiService: AIService
    @ObservedObject private var modeManager = ModeManager.shared
    @ObservedObject var audioDeviceManager = AudioDeviceManager.shared
    @AppStorage("hasCompletedOnboardingV2") private var hasCompletedOnboardingV2 = false
    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ninoHeader

            if hasCompletedOnboardingV2 {
                completedOnboardingMenu
            } else {
                onboardingMenu
            }
        }
        .padding(10)
        .frame(width: 260)
        .background(AppTheme.Nino.charcoal)
        .foregroundStyle(AppTheme.Nino.ivory)
        .tint(AppTheme.Nino.gold)
        .buttonStyle(.plain)
    }

    /// Nino brand mark: gold orb + wordmark, with a gold hairline underneath. This is the
    /// dropdown's first impression, so it needs to read as Nino-branded, not a plain system menu.
    private var ninoHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [AppTheme.Nino.gold, AppTheme.Nino.gold.opacity(0.55)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 8
                        )
                    )
                    .frame(width: 14, height: 14)

                Text("Nino Voice")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.Nino.ivory)
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 8)

            ninoDivider
        }
    }

    private var onboardingMenu: some View {
        Group {
            Button("Complete Onboarding") {
                menuBarManager.focusMainWindow()
            }

            ninoDivider

            Button("Quit Nino Voice") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// Thin gold-tinted hairline standing in for `Divider()`, which renders using the
    /// system separator color and is barely visible against the charcoal background.
    private var ninoDivider: some View {
        Rectangle()
            .fill(AppTheme.Nino.gold.opacity(0.18))
            .frame(height: 1)
            .padding(.vertical, 4)
    }

    private var isRecordingActive: Bool {
        engine.recordingState == .recording || engine.recordingState == .starting
    }

    private var completedOnboardingMenu: some View {
        Group {
            // Click-to-use entry point: starts (or stops) dictation with the current
            // default/active mode via the same recorderUIManager.toggleRecorderPanel()
            // path the primary hotkey drives — no hotkey needs to be remembered.
            Button {
                Task {
                    await recorderUIManager.toggleRecorderPanel()
                }
            } label: {
                Label(
                    isRecordingActive ? String(localized: "Stop Dictation") : String(localized: "Start Dictation"),
                    systemImage: isRecordingActive ? "stop.circle.fill" : "mic.circle.fill"
                )
                .foregroundStyle(isRecordingActive ? AppTheme.Nino.gold : AppTheme.Nino.ivory)
            }

            ninoDivider

            Menu {
                ForEach(modeManager.enabledConfigurations) { config in
                    Button {
                        // Same direct per-mode start path used by per-mode hotkeys
                        // (ModeShortcutManager -> toggleRecorderPanel(modeId:)): it
                        // activates this mode and immediately begins recording in it.
                        Task {
                            await recorderUIManager.toggleRecorderPanel(modeId: config.id)
                        }
                    } label: {
                        let isActive = modeManager.currentEffectiveConfiguration?.id == config.id
                        Text(isActive ? "\(config.name)  ✓" : config.name)
                    }
                }

                if modeManager.enabledConfigurations.isEmpty {
                    Text("No modes available")
                        .foregroundColor(.secondary)
                }

                Divider()

                Button("Manage Modes") {
                    menuBarManager.openMainWindowAndNavigate(to: "Modes")
                }

                Button("Manage Models") {
                    menuBarManager.openMainWindowAndNavigate(to: "AI Models")
                }
            } label: {
                HStack {
                    Image(systemName: "sparkles.square.fill.on.square")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.Nino.gold)
                    let activeMode = modeManager.currentEffectiveConfiguration
                    Text(String(format: String(localized: "Mode: %@"), activeMode?.name ?? String(localized: "None")))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.Nino.gold.opacity(0.8))
                }
            }

            Menu {
                ForEach(audioDeviceManager.availableDevices, id: \.id) { device in
                    Button {
                        audioDeviceManager.selectDeviceAndSwitchToCustomMode(id: device.id)
                    } label: {
                        let isActive = audioDeviceManager.getCurrentDevice() == device.id
                        Text(isActive ? "\(device.name)  ✓" : device.name)
                    }
                }

                if audioDeviceManager.availableDevices.isEmpty {
                    Text("No devices available")
                        .foregroundColor(.secondary)
                }
            } label: {
                HStack {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.Nino.gold)
                    Text("Audio Input")
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.Nino.gold.opacity(0.8))
                }
            }

            ninoDivider

            Button("Retry Last Transcription") {
                LastTranscriptionService.retryLastTranscription(
                    from: engine.modelContext,
                    transcriptionModelManager: transcriptionModelManager,
                    serviceRegistry: engine.serviceRegistry,
                    enhancementService: enhancementService
                )
            }

            Button("Copy Last Transcription") {
                LastTranscriptionService.copyLastTranscription(from: engine.modelContext)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            
            Button("History") {
                menuBarManager.openHistoryWindow()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            
            Button(menuBarManager.isMenuBarOnly ? "Show Dock Icon" : "Hide Dock Icon") {
                menuBarManager.toggleMenuBarOnly()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Toggle("Launch at Login", isOn: $launchAtLoginEnabled)
                .onChange(of: launchAtLoginEnabled) { oldValue, newValue in
                    LaunchAtLogin.isEnabled = newValue
                }

            ninoDivider

            Button("Settings") {
                menuBarManager.openMainWindowAndNavigate(to: "Settings")
            }
            .keyboardShortcut(",", modifiers: .command)

            if let update = updateCheckService.availableUpdate {
                Button("Update available — Download (v\(update.version))") {
                    updateCheckService.openDownloadPage()
                }
            }

            Button("Check for Updates") {
                updaterViewModel.checkForUpdates()
            }
            .disabled(!updaterViewModel.canCheckForUpdates)

            Button("Quit Nino Voice") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
