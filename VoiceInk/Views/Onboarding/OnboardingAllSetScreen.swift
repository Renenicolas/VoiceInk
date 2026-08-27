import SwiftUI

struct OnboardingAllSetScreen: View {
    let onFinish: () -> Void

    var body: some View {
        OnboardingStepScreen(stage: .allSet, contentMaxWidth: 520, showsHeader: false) {
            VStack(spacing: 22) {
                Image(systemName: "checkmark")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(NinoPalette.ink)
                    .frame(width: 72, height: 72)
                    .background(NinoPalette.gold2, in: Circle())

                Text("You're all set.")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(NinoPalette.cream)

                Text("Nino Voice is ready from any app.")
                    .font(.system(size: 15))
                    .foregroundStyle(NinoPalette.creamDim)
            }
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: nil,
                primaryTitle: "Open Nino Voice",
                isPrimaryEnabled: true,
                placement: .centered,
                onLeading: nil,
                onPrimary: onFinish
            )
        }
    }
}
