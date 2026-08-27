import SwiftUI

struct OnboardingWelcomeScreen: View {
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            OnboardingGoldBackground()

            VStack(spacing: 22) {
                Image(systemName: "waveform")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(NinoPalette.ink)
                    .frame(width: 76, height: 76)
                    .background(NinoPalette.gold2, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                Text("Your voice, ready wherever you work.")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(NinoPalette.cream)

                HStack(spacing: 8) {
                    Text("Getting Nino ready")
                        .foregroundStyle(NinoPalette.creamDim)
                    OnboardingPulsingDots()
                }
                .font(.system(size: 13, weight: .medium))

                Button("Get started", action: onContinue)
                    .buttonStyle(NinoPrimaryButtonStyle())
                    .padding(.top, 10)
            }
        }
    }
}

private struct OnboardingPulsingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isActive = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(NinoPalette.gold2)
                    .frame(width: 5, height: 5)
                    .opacity(reduceMotion || isActive ? 1 : 0.3)
                    .animation(
                        reduceMotion ? .linear(duration: 0) :
                            .easeInOut(duration: 0.8).repeatForever().delay(Double(index) * 0.16),
                        value: isActive
                    )
            }
        }
        .onAppear { isActive = true }
    }
}
