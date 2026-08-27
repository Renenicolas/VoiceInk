import SwiftUI
import AppKit

enum AppWindowLayout {
    static let width: CGFloat = 950
    static let minimumHeight: CGFloat = 730
}

class WindowManager: NSObject {
    static let shared = WindowManager()

    private static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("com.prakashjoshipax.voiceink.mainWindow")
    private static let mainWindowAutosaveName = NSWindow.FrameAutosaveName("VoiceInkMainWindowFrame")

    private var mainWindow: NSWindow?
    private var didApplyInitialPlacement = false
    private var isConfiguredForOnboarding = false

    private override init() {
        super.init()
    }
    
    func configureWindow(_ window: NSWindow) {
        if let existingWindow = NSApplication.shared.windows.first(where: { $0.identifier == Self.mainWindowIdentifier && $0 != window }) {
            window.close()
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }
        
        let requiredStyleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        if isConfiguredForOnboarding {
            window.styleMask = requiredStyleMask
            isConfiguredForOnboarding = false
            didApplyInitialPlacement = false
        } else {
            window.styleMask.formUnion(requiredStyleMask)
        }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.title = "Nino Voice"
        window.collectionBehavior = [.fullScreenPrimary]
        window.level = .normal
        window.isOpaque = false
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: AppWindowLayout.width, height: AppWindowLayout.minimumHeight)
        window.maxSize = NSSize(width: AppWindowLayout.width, height: CGFloat.greatestFiniteMagnitude)
        window.setFrameAutosaveName(Self.mainWindowAutosaveName)
        applyInitialPlacementIfNeeded(to: window)
        registerMainWindowIfNeeded(window)
        window.orderFrontRegardless()
    }

    func configureOnboardingWindow(_ window: NSWindow) {
        registerMainWindowIfNeeded(window)
        isConfiguredForOnboarding = true

        window.styleMask = [.borderless]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        // .normal, not .floating. At .floating this window sits above System
        // Settings, so the "Allow" buttons open a panel the user cannot see or
        // click — Rene hit exactly that and could not grant Accessibility.
        // Lemon's onboarding lets other windows come forward; so does this.
        window.level = .normal
        window.minSize = .zero
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        // Set the frame, then set it AGAIN on the next run-loop turn.
        //
        // SwiftUI owns this window: `.defaultSize` and `.windowResizability`
        // re-apply a content-sized frame after the WindowAccessor callback runs,
        // so a single setFrame here is silently undone and onboarding renders as
        // a small dialog in the middle of a big screen — which is exactly what it
        // did. Re-applying after SwiftUI has had its turn is what makes it stick.
        applyOnboardingFrame(to: window)
        DispatchQueue.main.async { [weak self] in
            self?.applyOnboardingFrame(to: window)
        }

        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Fill the screen the pointer is on, falling back to the main display.
    private func applyOnboardingFrame(to window: NSWindow) {
        guard isConfiguredForOnboarding else { return }
        let screen = window.screen ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        if window.frame != frame {
            window.setFrame(frame, display: true)
        }
    }
    
    func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
        window.identifier = Self.mainWindowIdentifier
        window.delegate = self
    }
    
    func showMainWindow() -> NSWindow? {
        guard let window = resolveMainWindow() else {
            return nil
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return window
    }
    
    func hideMainWindow() {
        guard let window = resolveMainWindow() else {
            return
        }

        window.orderOut(nil)
    }
    
    func currentMainWindow() -> NSWindow? {
        resolveMainWindow()
    }
    
    private func registerMainWindowIfNeeded(_ window: NSWindow) {
        // Only register the primary content window, identified by the hidden title bar style
        if window.identifier == nil || window.identifier != Self.mainWindowIdentifier {
            registerMainWindow(window)
        }
    }
    
    private func applyInitialPlacementIfNeeded(to window: NSWindow) {
        guard !didApplyInitialPlacement else { return }
        // Attempt to restore previous frame if one exists; otherwise fall back to a centered placement
        if window.setFrameUsingName(Self.mainWindowAutosaveName) {
            enforceMainWindowFrameIfNeeded(on: window, preserveRestoredOrigin: true)
        } else {
            enforceMainWindowFrameIfNeeded(on: window, preserveRestoredOrigin: false)
            window.center()
        }
        didApplyInitialPlacement = true
    }

    private func enforceMainWindowFrameIfNeeded(on window: NSWindow, preserveRestoredOrigin: Bool) {
        let currentFrame = window.frame
        guard currentFrame.width != AppWindowLayout.width || currentFrame.height < AppWindowLayout.minimumHeight else {
            return
        }

        let height = max(currentFrame.height, AppWindowLayout.minimumHeight)
        let x = preserveRestoredOrigin ? currentFrame.origin.x : currentFrame.midX - (AppWindowLayout.width / 2)
        let frame = NSRect(
            x: x,
            y: currentFrame.maxY - height,
            width: AppWindowLayout.width,
            height: height
        )
        window.setFrame(frame, display: true)
    }
    
    private func resolveMainWindow() -> NSWindow? {
        if let window = mainWindow {
            return window
        }

        if let window = NSApplication.shared.windows.first(where: { $0.identifier == Self.mainWindowIdentifier }) {
            mainWindow = window
            window.delegate = self
            return window
        }

        return nil
    }

    private func restoreAccessoryPolicyIfNeededAfterWindowHide() {
        guard UserDefaults.standard.bool(forKey: "IsMenuBarOnly") else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let hasVisibleWindows = NSApplication.shared.windows.contains {
                $0.isVisible && $0.level == .normal && !$0.styleMask.contains(.nonactivatingPanel)
            }

            if !hasVisibleWindows && NSApplication.shared.activationPolicy() != .accessory {
                NSApplication.shared.setActivationPolicy(.accessory)
            }
        }
    }
}

extension WindowManager: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.identifier == Self.mainWindowIdentifier else {
            return true
        }

        sender.orderOut(nil)
        restoreAccessoryPolicyIfNeededAfterWindowHide()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window.identifier == Self.mainWindowIdentifier {
            mainWindow = nil
            didApplyInitialPlacement = false
        }
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier == Self.mainWindowIdentifier else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
} 
