import AppKit
import SwiftUI

struct OnboardingShortcutsScreen: View {
    let contentMaxWidth: CGFloat
    let onBack: () -> Void
    let onContinue: () -> Void
    @State private var pressedShortcut: NinoOnboardingShortcut?

    var body: some View {
        ZStack {
            OnboardingGoldBackground()

            OnboardingStepScreen(
                systemImage: OnboardingStage.shortcuts.systemImage,
                title: "Four keys. Nino everywhere.",
                subtitle: "Press any one of these shortcuts now to continue.",
                contentMaxWidth: max(contentMaxWidth, 620)
            ) {
                VStack(spacing: 10) {
                    ForEach(NinoOnboardingShortcut.allCases) { shortcut in
                        shortcutRow(shortcut)
                    }
                }
                .background(ShortcutKeyEventObserver { pressedShortcut = $0 })
            } bottomBar: {
                OnboardingBottomBar(
                    leadingTitle: "Back",
                    primaryTitle: pressedShortcut == nil ? "Press a shortcut" : "Looks good",
                    isPrimaryEnabled: pressedShortcut != nil,
                    onLeading: onBack,
                    onPrimary: onContinue
                )
            }
        }
    }

    private func shortcutRow(_ shortcut: NinoOnboardingShortcut) -> some View {
        HStack(spacing: 16) {
            Text(shortcut.keyLabel)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(pressedShortcut == shortcut ? NinoPalette.ink : NinoPalette.gold2)
                .frame(width: 132, height: 34)
                .background(
                    pressedShortcut == shortcut ? NinoPalette.gold2 : NinoPalette.surface3,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(shortcut.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NinoPalette.cream)
                Text(shortcut.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(NinoPalette.creamDim)
            }

            Spacer()

            if pressedShortcut == shortcut {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(NinoPalette.gold2)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 66)
        .background(NinoPalette.surface.opacity(0.88), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(NinoPalette.border, lineWidth: 1)
        }
    }
}

enum NinoOnboardingShortcut: String, CaseIterable, Identifiable {
    case rightOption
    case rightCommand
    case commandOption
    case leftOption

    var id: String { rawValue }

    var keyLabel: String {
        switch self {
        case .rightOption: "Right-Option"
        case .rightCommand: "Right-Command"
        case .commandOption: "Command+Option"
        case .leftOption: "Left-Option"
        }
    }

    var title: String {
        switch self {
        case .rightOption: "Hold to talk"
        case .rightCommand: "Ask Nino"
        case .commandOption: "Enhanced, per-app voice"
        case .leftOption: "Paste last"
        }
    }

    var detail: String {
        switch self {
        case .rightOption: "Raw transcript, no AI"
        case .rightCommand: "Ask a question from anywhere"
        case .commandOption: "Nino matches how you write in each app"
        case .leftOption: "Paste your most recent result again"
        }
    }
}

private struct ShortcutKeyEventObserver: NSViewRepresentable {
    let onShortcut: (NinoOnboardingShortcut) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onShortcut: onShortcut) }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onShortcut = onShortcut
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var onShortcut: (NinoOnboardingShortcut) -> Void
        private var monitor: Any?

        init(onShortcut: @escaping (NinoOnboardingShortcut) -> Void) {
            self.onShortcut = onShortcut
        }

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
                guard let shortcut = Self.shortcut(for: event) else { return event }
                self?.onShortcut(shortcut)
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private static func shortcut(for event: NSEvent) -> NinoOnboardingShortcut? {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains([.command, .option]) { return .commandOption }
            switch event.keyCode {
            case 61 where flags.contains(.option): return .rightOption
            case 54 where flags.contains(.command): return .rightCommand
            case 58 where flags.contains(.option): return .leftOption
            default: return nil
            }
        }
    }
}
