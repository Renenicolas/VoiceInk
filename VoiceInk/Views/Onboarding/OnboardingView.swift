import SwiftUI
import AppKit

struct OnboardingView: View {
    @Binding var hasCompletedOnboardingV2: Bool
    @EnvironmentObject var fluidAudioModelManager: FluidAudioModelManager
    @EnvironmentObject var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject var aiService: AIService
    @EnvironmentObject var enhancementService: AIEnhancementService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var coordinator = OnboardingCoordinator()
    @State private var isShowingSkipOnboardingConfirmation = false

    let contentMaxWidth: CGFloat = 560

    var body: some View {
        let isTranscriptionModelDownloaded = coordinator.isTranscriptionModelDownloaded(
            using: fluidAudioModelManager
        )
        let isTranscriptionSetupReady = coordinator.isTranscriptionSetupReady(
            isTranscriptionModelDownloaded: isTranscriptionModelDownloaded
        )

        ZStack(alignment: .bottomLeading) {
            OnboardingBackground()

            Group {
                switch coordinator.stage {
                case .welcome:
                    OnboardingWelcomeScreen(onContinue: coordinator.flow.goToIntentStep)
                case .intent:
                    OnboardingIntentScreen(
                        intent: $coordinator.onboardingIntent,
                        onBack: coordinator.flow.goBackToWelcomeStep,
                        onContinue: coordinator.flow.goToPermissionsStep
                    )
                case .permissions:
                    OnboardingPermissionsScreen(
                        contentMaxWidth: contentMaxWidth,
                        isComplete: coordinator.requiredPermissionsGranted,
                        activePermission: coordinator.activePermission,
                        hasRequestedScreenRecording: coordinator.hasRequestedScreenRecording,
                        stepNumber: { coordinator.permissions.stepNumber(for: $0) },
                        status: { coordinator.permissions.status(for: $0) },
                        isLocked: { coordinator.permissions.isLocked($0) },
                        actionTitle: { coordinator.permissions.actionTitle(for: $0) },
                        onSelect: coordinator.permissions.setActivePermission,
                        onAction: coordinator.permissions.performAction,
                        onQuit: {
                            NSApplication.shared.terminate(nil)
                        },
                        onRecheck: coordinator.permissions.refreshPermissionStatuses,
                        onContinue: coordinator.flow.goToMicrophoneStep
                    )
                case .microphone:
                    OnboardingMicrophoneScreen(
                        contentMaxWidth: contentMaxWidth,
                        onBack: coordinator.flow.goToPermissionsStep,
                        onContinue: coordinator.flow.goToModelStep
                    )
                case .model:
                    OnboardingModelScreen(
                        contentMaxWidth: contentMaxWidth,
                        localModel: coordinator.requiredTranscriptionModel,
                        setupKind: coordinator.transcriptionSetupKind,
                        providerOptions: coordinator.onboardingTranscriptionProviderOptions,
                        selectedProviderKey: coordinator.selectedOnboardingTranscriptionProviderKeyBinding(),
                        isLocalDownloaded: isTranscriptionModelDownloaded,
                        isLocalDownloading: coordinator.requiredTranscriptionModel.map {
                            fluidAudioModelManager.isFluidAudioModelDownloading($0)
                        } ?? false,
                        localDownloadStatus: coordinator.requiredTranscriptionModel.flatMap {
                            fluidAudioModelManager.downloadStatus(for: $0)
                        },
                        isSetupReady: isTranscriptionSetupReady,
                        onSelectSetupKind: coordinator.flow.selectOnboardingTranscriptionSetup,
                        onDownload: {
                            coordinator.flow.downloadTranscriptionModel(
                                $0,
                                modelManager: fluidAudioModelManager
                            )
                        },
                        onVerificationChanged: coordinator.flow.refreshTranscriptionSetupVerification,
                        onBack: coordinator.flow.goToMicrophoneStep,
                        onContinue: {
                            coordinator.flow.goToAPIStep(
                                isTranscriptionSetupReady: isTranscriptionSetupReady,
                                aiService: aiService
                            )
                        }
                    )
                case .api:
                    OnboardingAPIScreen(
                        aiService: aiService,
                        contentMaxWidth: contentMaxWidth,
                        providerOptions: coordinator.onboardingProviderOptions,
                        selectedProvider: coordinator.selectedOnboardingProviderBinding(aiService: aiService),
                        isSelectedProviderVerified: coordinator.isSelectedAPIProviderVerified,
                        canContinue: coordinator.isReadyForExperience(
                            isTranscriptionSetupReady: isTranscriptionSetupReady
                        ),
                        isShowingSkipWarning: $coordinator.isShowingSkipAPISetupWarning,
                        onVerificationChanged: coordinator.flow.refreshAPIVerification,
                        onBack: coordinator.flow.goBackToModelStep,
                        onContinue: {
                            coordinator.flow.goToExperienceStep(
                                isTranscriptionSetupReady: isTranscriptionSetupReady,
                                enhancementService: enhancementService
                            )
                        },
                        onRequestSkip: coordinator.flow.requestSkipAPISetup,
                        onConfirmSkip: {
                            coordinator.flow.skipAPISetupAndContinue(
                                isTranscriptionSetupReady: isTranscriptionSetupReady,
                                enhancementService: enhancementService
                            )
                        }
                    )
                case .experience:
                    OnboardingExperienceScreen(
                        step: coordinator.experienceStep,
                        isInIntroPhase: coordinator.isShowingExperienceIntroPhase,
                        shortcutAction: coordinator.experienceShortcutAction,
                        hasShortcut: coordinator.hasExperienceModeShortcut,
                        text: coordinator.currentExperienceText,
                        isLastStep: coordinator.isLastExperienceStep,
                        isReady: coordinator.isCurrentExperienceReady(
                            isTranscriptionSetupReady: isTranscriptionSetupReady
                        ),
                        isComplete: coordinator.isCurrentExperienceComplete,
                        onBackFromIntro: {
                            coordinator.flow.goToPreviousExperienceStep(enhancementService: enhancementService)
                        },
                        onContinueIntro: coordinator.flow.goToExperiencePracticePhase,
                        onBackFromPractice: {
                            coordinator.flow.goBackFromExperiencePractice(enhancementService: enhancementService)
                        },
                        onAdvance: {
                            coordinator.flow.advanceExperienceStep(
                                isTranscriptionSetupReady: isTranscriptionSetupReady,
                                enhancementService: enhancementService
                            )
                        },
                        onShortcutChanged: {
                            coordinator.flow.refreshExperienceModeState(enhancementService: enhancementService)
                        },
                        onAppear: coordinator.flow.activateExperienceModeForDemo
                    )
                case .contextAwareness:
                    OnboardingContextAwarenessScreen(
                        contentMaxWidth: contentMaxWidth,
                        onBack: {
                            coordinator.flow.goToPreviousContextAwarenessStep(
                                enhancementService: enhancementService
                            )
                        },
                        onContinue: {
                            coordinator.flow.continueFromContextAwarenessStep(
                                enhancementService: enhancementService
                            )
                        }
                    )
                case .trust:
                    OnboardingTrustScreen(
                        contentMaxWidth: contentMaxWidth,
                        onBack: {
                            coordinator.flow.goToPreviousTrustStep(
                                isTranscriptionSetupReady: isTranscriptionSetupReady,
                                enhancementService: enhancementService
                            )
                        },
                        onContinue: {
                            coordinator.flow.goToShortcutsStep(
                                isTranscriptionSetupReady: isTranscriptionSetupReady
                            )
                        }
                    )
                case .shortcuts:
                    OnboardingShortcutsScreen(
                        contentMaxWidth: contentMaxWidth,
                        onBack: {
                            coordinator.flow.goToPreviousShortcutsStep(
                                isTranscriptionSetupReady: isTranscriptionSetupReady
                            )
                        },
                        onContinue: {
                            coordinator.flow.goToLicenseStep(
                                isTranscriptionSetupReady: isTranscriptionSetupReady
                            )
                        }
                    )
                case .license:
                    OnboardingLicenseScreen(
                        licenseViewModel: coordinator.licenseViewModel,
                        onBack: {
                            coordinator.flow.goToPreviousLicenseStep(
                                isTranscriptionSetupReady: isTranscriptionSetupReady
                            )
                        },
                        onPurchase: {
                            coordinator.licenseViewModel.openPurchaseLink()
                        },
                        onStartTrial: {
                            coordinator.flow.startLicenseTrial(
                                isTranscriptionSetupReady: isTranscriptionSetupReady
                            ) {
                                coordinator.flow.goToAllSetStep(
                                    isTranscriptionSetupReady: isTranscriptionSetupReady
                                )
                            }
                        },
                        onActivate: coordinator.flow.activateLicense,
                        onFinish: {
                            coordinator.flow.goToAllSetStep(
                                isTranscriptionSetupReady: isTranscriptionSetupReady
                            )
                        }
                    )
                case .allSet:
                    OnboardingAllSetScreen {
                        coordinator.flow.completeOnboarding(
                            isTranscriptionSetupReady: isTranscriptionSetupReady
                        ) {
                            hasCompletedOnboardingV2 = true
                        }
                    }
                }
            }
            .transition(.ninoOnboardingStep)
            .id(coordinator.stage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            OnboardingProgressBadge(
                currentStep: coordinator.currentStepNumber,
                totalSteps: coordinator.totalStepCount
            )
            .padding(.leading, 28)
            .padding(.bottom, 26)
            .allowsHitTesting(false)

            if shouldShowSkipOnboardingButton {
                skipOnboardingButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 22)
                    .padding(.trailing, 28)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 820, minHeight: 680)
        .animation(.easeInOut(duration: reduceMotion ? 0 : 0.24), value: coordinator.stage)
        .animation(.easeInOut(duration: reduceMotion ? 0 : 0.18), value: shouldShowSkipOnboardingButton)
        .alert("Skip onboarding?", isPresented: $isShowingSkipOnboardingConfirmation) {
            Button("Continue", role: .cancel) { }
            Button("Skip Onboarding", role: .destructive) {
                coordinator.flow.skipOnboarding {
                    hasCompletedOnboardingV2 = true
                }
            }
        } message: {
            Text("It is recommended that you complete the onboarding.")
        }
        .onAppear {
            coordinator.flow.ensureDefaultOnboardingTranscriptionProvider()
            coordinator.flow.refreshTranscriptionSetupVerification()
            coordinator.flow.ensureDefaultOnboardingProvider()
            coordinator.permissions.refreshPermissionStatuses()
            coordinator.flow.refreshAPIVerification()
            coordinator.flow.refreshExperienceModeState(enhancementService: enhancementService)
            let refreshedTranscriptionSetupReady = coordinator.isTranscriptionSetupReady(
                isTranscriptionModelDownloaded: isTranscriptionModelDownloaded
            )
            coordinator.flow.reconcileStage(
                isTranscriptionSetupReady: refreshedTranscriptionSetupReady,
                enhancementService: enhancementService
            )
        }
        .onDisappear {
            coordinator.permissions.cancelRefreshTask()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            coordinator.permissions.refreshPermissionStatuses()
            coordinator.flow.refreshTranscriptionSetupVerification()
            let refreshedTranscriptionSetupReady = coordinator.isTranscriptionSetupReady(
                isTranscriptionModelDownloaded: isTranscriptionModelDownloaded
            )
            coordinator.flow.reconcileStage(
                isTranscriptionSetupReady: refreshedTranscriptionSetupReady,
                enhancementService: enhancementService
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            coordinator.permissions.refreshPermissionStatuses()
        }
        .onReceive(NotificationCenter.default.publisher(for: .aiProviderKeyChanged)) { _ in
            coordinator.flow.refreshAPIVerification()
            coordinator.flow.refreshTranscriptionSetupVerification()
        }
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.shortcutDidChange)) { notification in
            guard let action = notification.object as? ShortcutAction,
                  action == coordinator.experienceShortcutAction else {
                return
            }

            coordinator.flow.refreshExperienceModeState(enhancementService: enhancementService)
        }
        .onReceive(NotificationCenter.default.publisher(for: .modeConfigurationsDidChange)) { _ in
            coordinator.flow.refreshExperienceModeState(enhancementService: enhancementService)
        }
        .onChange(of: coordinator.stage) { _, _ in
            coordinator.flow.activateExperienceModeForDemo()
            coordinator.flow.refreshExperienceModeState(enhancementService: enhancementService)
        }
    }

    private var shouldShowSkipOnboardingButton: Bool {
        coordinator.requiredPermissionsGranted &&
            coordinator.stage != .permissions &&
            coordinator.stage != .allSet
    }

    private var skipOnboardingButton: some View {
        Button {
            isShowingSkipOnboardingConfirmation = true
        } label: {
            Text("Skip")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(NinoPalette.creamDim)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(
                    Capsule()
                        .fill(NinoPalette.surface3)
                )
        }
        .buttonStyle(.plain)
        .help("Skip onboarding")
    }
}

#Preview {
    OnboardingView(hasCompletedOnboardingV2: .constant(false))
}
