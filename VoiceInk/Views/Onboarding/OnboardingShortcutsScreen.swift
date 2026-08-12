import SwiftUI

struct OnboardingShortcutsScreen: View {
    let contentMaxWidth: CGFloat
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        OnboardingStepScreen(
            systemImage: OnboardingStage.shortcuts.systemImage,
            title: OnboardingStage.shortcuts.title,
            subtitle: OnboardingStage.shortcuts.subtitle,
            contentMaxWidth: max(contentMaxWidth, 560),
            showsHeader: true
        ) {
            OnboardingShortcutsList()
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: "Back",
                primaryTitle: "Continue",
                isPrimaryEnabled: true,
                onLeading: onBack,
                onPrimary: onContinue
            )
        }
    }
}

/// Each row binds a distinct, user-assignable ``ShortcutAction``. Conflict
/// checking and persistence are handled entirely by ``ShortcutRecorder`` /
/// ``ShortcutStore`` — this view only supplies the four actions and labels.
private struct OnboardingShortcutsList: View {
    private static let dictationModeId = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private static let liveAnswersModeId = UUID(uuidString: "10000000-0000-0000-0000-000000000008")!

    private struct Row: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let action: ShortcutAction
    }

    private var rows: [Row] {
        [
            Row(
                id: "primaryRecording",
                title: String(localized: "Magic Modes"),
                subtitle: String(localized: "Start recording with your active, app-aware mode."),
                action: .primaryRecording
            ),
            Row(
                id: "dictation",
                title: String(localized: "Pure Transcription"),
                subtitle: String(localized: "Jump straight to raw dictation, no AI enhancement."),
                action: .mode(Self.dictationModeId)
            ),
            Row(
                id: "liveAnswers",
                title: String(localized: "Answers Live"),
                subtitle: String(localized: "Ask a question with live web search."),
                action: .mode(Self.liveAnswersModeId)
            ),
            Row(
                id: "pasteLastEnhancement",
                title: String(localized: "Paste Last Enhanced"),
                subtitle: String(localized: "Paste your most recent enhanced transcription again."),
                action: .pasteLastEnhancement
            )
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Divider().opacity(0.5)
                }

                shortcutRow(row)
            }
        }
        .background(AppTheme.Surface.control.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.Border.subtle, lineWidth: 1)
        )
    }

    private func shortcutRow(_ row: Row) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(row.title))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppTheme.Text.primary)

                Text(LocalizedStringKey(row.subtitle))
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.Text.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            OnboardingShortcutSetupView(action: row.action) {}
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}
