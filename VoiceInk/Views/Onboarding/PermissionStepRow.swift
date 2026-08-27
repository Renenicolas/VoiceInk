import SwiftUI

struct PermissionStepRow: View {
    let stepNumber: Int
    let descriptor: OnboardingPermissionDescriptor
    let status: OnboardingPermissionStatus
    let isActive: Bool
    let isLocked: Bool
    let showsRestartHint: Bool
    let actionTitle: String
    let onSelect: () -> Void
    let onAction: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                stepNumberView

                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(descriptor.title))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(NinoPalette.cream)

                    Text(LocalizedStringKey(descriptor.subtitle))
                        .font(.system(size: 12))
                        .foregroundColor(NinoPalette.creamDim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                if status.isGranted || isLocked {
                    statusBadge
                } else {
                    actionButton
                }
            }

            if isActive && !isLocked && showsRestartHint {
                restartHint
                    .padding(.leading, 44)
            }
        }
        .padding(14)
        .background(isActive && !isLocked ? NinoPalette.surface3 : NinoPalette.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isActive && !isLocked ? NinoPalette.gold.opacity(0.45) : NinoPalette.border, lineWidth: 1)
        }
        .opacity(isLocked ? 0.55 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            guard !isLocked else { return }
            onSelect()
        }
    }

    private var stepNumberView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(status.isGranted ? NinoPalette.gold : NinoPalette.surface3)

            if status.isGranted {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(status.isGranted ? NinoPalette.ink : NinoPalette.cream)
            } else {
                Text("\(stepNumber)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isActive && !isLocked ? NinoPalette.cream : NinoPalette.creamDim)
            }
        }
        .frame(width: 30, height: 30)
    }

    private var actionButton: some View {
        Button(action: onAction) {
            Text(LocalizedStringKey(actionTitle))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(NinoPalette.ink)
                .frame(minWidth: 94)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.control, style: .continuous)
                        .fill(NinoPalette.gold2)
                )
        }
        .buttonStyle(.plain)
    }

    private var statusBadge: some View {
        Text(isLocked ? LocalizedStringKey("Locked") : LocalizedStringKey(status.label))
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(isLocked ? NinoPalette.creamDim : statusTone)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isLocked ? NinoPalette.surface3 : statusTone.opacity(0.16))
            .clipShape(Capsule())
    }

    private var statusTone: Color {
        switch status {
        case .granted:
            return NinoPalette.gold2
        case .denied, .restricted:
            return NinoPalette.gold
        default:
            return NinoPalette.creamDim
        }
    }

    private var restartHint: some View {
        HStack(spacing: 8) {
            Text("Restart Nino Voice after enabling Screen Recording.")
                .font(.system(size: 12))
                .foregroundColor(NinoPalette.creamDim)
                .fixedSize(horizontal: false, vertical: true)

            Button("Quit") {
                onQuit()
            }
            .font(.system(size: 12, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundColor(NinoPalette.gold2)
        }
    }
}
