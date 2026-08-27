import SwiftUI

struct OnboardingIntentScreen: View {
    @Binding var intent: String
    let onBack: () -> Void
    let onContinue: () -> Void

    private let chips = [
        "Write faster", "Ask Nino", "Polish my words", "Work across apps"
    ]

    var body: some View {
        OnboardingStepScreen(stage: .intent, contentMaxWidth: 620) {
            VStack(alignment: .leading, spacing: 16) {
                TextEditor(text: $intent)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(NinoPalette.cream)
                    .scrollContentBackground(.hidden)
                    .padding(18)
                    .frame(height: 150)
                    .background(NinoPalette.surface2, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(NinoPalette.border, lineWidth: 1)
                    }
                    .overlay(alignment: .topLeading) {
                        if intent.isEmpty {
                            Text("What do you want Nino to handle?")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(NinoPalette.creamDim)
                                .padding(24)
                                .allowsHitTesting(false)
                        }
                    }

                HStack(spacing: 8) {
                    ForEach(chips, id: \.self) { chip in
                        Button(chip) { intent = chip }
                            .buttonStyle(NinoChipButtonStyle(isSelected: intent == chip))
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("“Turn my rough notes into clear client updates.”")
                    Text("“Let me ask questions without leaving the app I’m in.”")
                }
                .font(.system(size: 12))
                .foregroundStyle(NinoPalette.creamDim)
            }
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: "Back",
                primaryTitle: "Continue",
                isPrimaryEnabled: !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                onLeading: onBack,
                onPrimary: onContinue
            )
        }
    }
}
