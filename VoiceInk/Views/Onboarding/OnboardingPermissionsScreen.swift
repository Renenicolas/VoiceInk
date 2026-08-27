import SwiftUI

struct OnboardingPermissionsScreen: View {
    let contentMaxWidth: CGFloat
    let isComplete: Bool
    let activePermission: OnboardingPermissionKind
    let hasRequestedScreenRecording: Bool
    let stepNumber: (OnboardingPermissionKind) -> Int
    let status: (OnboardingPermissionKind) -> OnboardingPermissionStatus
    let isLocked: (OnboardingPermissionKind) -> Bool
    let actionTitle: (OnboardingPermissionKind) -> String
    let onSelect: (OnboardingPermissionKind) -> Void
    let onAction: (OnboardingPermissionKind) -> Void
    let onQuit: () -> Void
    let onRecheck: () -> Void
    let onContinue: () -> Void

    var body: some View {
        OnboardingStepScreen(
            stage: .permissions,
            contentMaxWidth: contentMaxWidth
        ) {
            permissionList
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: "Recheck",
                primaryTitle: "Continue",
                isPrimaryEnabled: isComplete,
                onLeading: onRecheck,
                onPrimary: onContinue
            )
        }
    }

    private var permissionList: some View {
        VStack(spacing: 10) {
            ForEach(OnboardingPermissionKind.allCases) { permission in
                PermissionStepRow(
                    stepNumber: stepNumber(permission),
                    descriptor: permission.descriptor,
                    status: status(permission),
                    isActive: !isComplete && activePermission == permission,
                    isLocked: isLocked(permission),
                    showsRestartHint: permission == .screenRecording &&
                        hasRequestedScreenRecording &&
                        !status(.screenRecording).isGranted,
                    actionTitle: actionTitle(permission),
                    onSelect: {
                        guard !isLocked(permission) else { return }
                        onSelect(permission)
                    },
                    onAction: {
                        onAction(permission)
                    },
                    onQuit: onQuit
                )
            }

            Text("Microphone is required. Accessibility and Screen Recording are optional and can be enabled later.")
                .font(.system(size: 11))
                .foregroundStyle(NinoPalette.creamDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
    }
}
