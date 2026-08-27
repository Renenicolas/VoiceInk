import SwiftUI

enum OnboardingStage: String, CaseIterable {
    case welcome
    case intent
    case permissions
    case microphone
    case model
    case api
    case experience
    case contextAwareness
    case trust
    case shortcuts
    case license
    case allSet

    var stepNumber: Int {
        switch self {
        case .welcome:
            return 1
        case .intent:
            return 2
        case .permissions:
            return 3
        case .microphone:
            return 4
        case .model:
            return 5
        case .api:
            return 6
        case .experience:
            return 5
        case .contextAwareness:
            return 6
        case .trust:
            return 7
        case .shortcuts:
            return 8
        case .license:
            return 9
        case .allSet:
            return 10
        }
    }

    var systemImage: String {
        switch self {
        case .welcome:
            return "sparkles"
        case .intent:
            return "text.bubble"
        case .permissions:
            return "lock.shield"
        case .microphone:
            return "mic"
        case .model:
            return "captions.bubble"
        case .api:
            return "checkmark.seal"
        case .experience:
            return "square.grid.2x2.fill"
        case .contextAwareness:
            return "slider.horizontal.3"
        case .trust:
            return "lock.shield"
        case .shortcuts:
            return "keyboard"
        case .license:
            return "checkmark.seal.fill"
        case .allSet:
            return "checkmark"
        }
    }

    var title: String {
        switch self {
        case .welcome:
            return String(localized: "Meet Nino Voice")
        case .intent:
            return String(localized: "Nino works for you.")
        case .permissions:
            return String(localized: "Allow Permissions")
        case .microphone:
            return String(localized: "Choose Microphone")
        case .model:
            return String(localized: "Configure Transcription Model")
        case .api:
            return String(localized: "Verify API Key")
        case .experience:
            return String(localized: "Experience Nino Voice")
        case .contextAwareness:
            return String(localized: "Nino Voice is Context-Aware")
        case .trust:
            return String(localized: "Nino Voice is Open Source")
        case .shortcuts:
            return String(localized: "Set Your Shortcuts")
        case .license:
            return String(localized: "Buy Nino Voice License")
        case .allSet:
            return String(localized: "You're all set.")
        }
    }

    var subtitle: String {
        switch self {
        case .welcome:
            return String(localized: "Your voice, ready wherever you work.")
        case .intent:
            return String(localized: "Tell Nino what would make your day easier before we set anything up.")
        case .permissions:
            return String(localized: "Allow Nino Voice to work across all your apps.")
        case .microphone:
            return String(localized: "Pick the microphone Nino Voice should use for recordings.")
        case .model:
            return String(localized: "Use NVIDIA's Parakeet model locally, or connect a cloud transcription provider.")
        case .api:
            return String(localized: "Nino Voice uses LLMs to enhance transcripts and perform AI actions. Set up an API key before continuing.")
        case .experience:
            return String(localized: "Try a few short samples and see how Nino Voice works before you start.")
        case .contextAwareness:
            return String(localized: "Nino Voice can select the right mode from the app you are using and the rules you configure.")
        case .trust:
            return String(localized: "Nino Voice is private by default. No data leaves your device unless you opt in.")
        case .shortcuts:
            return String(localized: "Choose your own keys for these actions. Pick keys that don't conflict with other apps you use. You can change these anytime in Settings.")
        case .license:
            return String(localized: "Activate an existing key, purchase a license, or start a 7-day free trial.")
        case .allSet:
            return String(localized: "Nino Voice is ready from any app.")
        }
    }

    static var baseStepCount: Int {
        6
    }
}

enum OnboardingPermissionKind: String, CaseIterable, Identifiable {
    case microphone
    case accessibility
    case screenRecording

    var id: String { rawValue }

    static var required: [OnboardingPermissionKind] {
        [.microphone]
    }

    var isRequired: Bool {
        Self.required.contains(self)
    }

    var descriptor: OnboardingPermissionDescriptor {
        switch self {
        case .microphone:
            return OnboardingPermissionDescriptor(
                title: "Microphone",
                subtitle: String(localized: "Nino Voice uses your microphone to capture your voice.")
            )

        case .accessibility:
            return OnboardingPermissionDescriptor(
                title: String(localized: "Accessibility"),
                subtitle: String(localized: "Nino Voice uses Accessibility to type transcriptions directly into any app.")
            )

        case .screenRecording:
            return OnboardingPermissionDescriptor(
                title: String(localized: "Screen Recording"),
                subtitle: String(localized: "Nino Voice reads visible screen content to improve the accuracy of transcripts.")
            )
        }
    }
}

struct OnboardingPermissionDescriptor {
    let title: String
    let subtitle: String
}

enum OnboardingPermissionStatus: Equatable {
    case granted
    case needsAccess
    case denied
    case restricted
    case unknown

    var isGranted: Bool {
        self == .granted
    }

    var requiresSettings: Bool {
        self == .denied || self == .restricted
    }

    var label: String {
        switch self {
        case .granted:
            return String(localized: "Granted")
        case .needsAccess:
            return String(localized: "Needs access")
        case .denied:
            return String(localized: "Denied")
        case .restricted:
            return String(localized: "Restricted")
        case .unknown:
            return String(localized: "Unknown")
        }
    }

    var color: Color {
        switch self {
        case .granted:
            return NinoPalette.creamDim
        case .needsAccess:
            return NinoPalette.creamDim
        case .denied, .restricted:
            return NinoPalette.gold
        case .unknown:
            return NinoPalette.creamDim
        }
    }
}

enum PrivacySettingsPane {
    case microphone
    case accessibility
    case screenRecording

    var urlString: String {
        switch self {
        case .microphone:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
    }
}
