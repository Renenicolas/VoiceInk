import Foundation
import AppKit

struct RecordingContextSnapshot {
    var capturedAt = Date()
    var selectedText: String?
    var clipboardText: String?
    var screenText: String?
    /// Bundle identifier of the frontmost app when this recording started. Powers
    /// per-app learned-voice style memory (see `PerAppStyleMemory`).
    var appBundleID: String?
}

@MainActor
final class RecordingContextSnapshotStore {
    private(set) var snapshot = RecordingContextSnapshot()

    func updateSelectedText(_ text: String?) {
        snapshot.selectedText = Self.normalized(text)
    }

    func updateClipboardText(_ text: String?) {
        snapshot.clipboardText = Self.normalized(text)
    }

    func updateScreenText(_ text: String?) {
        snapshot.screenText = Self.normalized(text)
    }

    func updateAppBundleID(_ bundleID: String?) {
        snapshot.appBundleID = Self.normalized(bundleID)
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
enum RecordingContextCaptureService {
    static func startCapture(into store: RecordingContextSnapshotStore) -> [Task<Void, Never>] {
        // Frontmost app is already known synchronously (ActiveWindowService set it when this
        // recording began) — capture it now rather than in a Task, so it reflects the app that
        // was frontmost at recording time, not whatever is frontmost when a Task later runs.
        store.updateAppBundleID(ActiveWindowService.shared.currentApplication?.bundleIdentifier)

        return [
            Task { @MainActor in
                store.updateClipboardText(NSPasteboard.general.string(forType: .string))
            },
            Task { @MainActor in
                guard !Task.isCancelled else { return }
                let selectedText = await SelectedTextService.fetchSelectedText()
                guard !Task.isCancelled else { return }
                store.updateSelectedText(selectedText)
            },
            Task { @MainActor in
                guard CGPreflightScreenCaptureAccess(), !Task.isCancelled else { return }
                let screenCaptureService = ScreenCaptureService()
                let screenText = await screenCaptureService.captureAndExtractText()
                guard !Task.isCancelled else { return }
                store.updateScreenText(screenText)
            }
        ]
    }
}
