import Foundation
import AppKit

struct RecordingContextSnapshot {
    var capturedAt = Date()
    var selectedText: String?
    var clipboardText: String?
    var screenText: String?
    /// Bundle identifier of the frontmost app when this recording started. Raw app identity —
    /// for the actual per-app-style-memory STORAGE KEY (which is instead a browser tab's
    /// domain when the frontmost app is a browser), see `styleContextKey`.
    var appBundleID: String?
    /// Per-app-style-memory storage key resolved at recording time (see
    /// `StyleContextKeyResolver`): `"web:<domain>"` when the frontmost app was a known browser
    /// and its active tab's URL was fetchable at capture time, else `"app:<bundleID>"`. May
    /// still be `nil` if the resolution task (browser URL fetch can take up to ~1.5s) hasn't
    /// completed yet when this snapshot is read — callers should fall back to deriving
    /// `"app:" + appBundleID` in that case (see `AIEnhancementService.resolvedStyleContextKey`).
    var styleContextKey: String?
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

    func updateStyleContextKey(_ key: String?) {
        snapshot.styleContextKey = Self.normalized(key)
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
        let bundleID = ActiveWindowService.shared.currentApplication?.bundleIdentifier
        store.updateAppBundleID(bundleID)

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
            },
            Task { @MainActor in
                guard !Task.isCancelled else { return }
                let key = await StyleContextKeyResolver.resolve(bundleID: bundleID)
                guard !Task.isCancelled else { return }
                store.updateStyleContextKey(key)
            }
        ]
    }
}
