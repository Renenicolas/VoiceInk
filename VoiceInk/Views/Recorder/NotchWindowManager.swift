import SwiftUI
import AppKit
import Combine

@MainActor
class NotchWindowManager {
    private var windowController: NSWindowController?
    private var panel: NotchRecorderPanel?
    private var assistantVisibilityCancellable: AnyCancellable?

    private let makeView: () -> AnyView
    private let assistantSession: AssistantSession

    init(
        engine: VoiceInkEngine,
        recorder: Recorder,
        assistantSession: AssistantSession,
        onRecordButtonTapped: @escaping () -> Void,
        onCloseTapped: @escaping () -> Void,
        onAssistantFollowUp: @escaping (String) -> Void
    ) {
        self.assistantSession = assistantSession
        self.makeView = {
            AnyView(
                NotchRecorderView(
                    stateProvider: engine,
                    recorder: recorder,
                    assistantSession: assistantSession,
                    onRecordButtonTapped: onRecordButtonTapped,
                    onCloseTapped: onCloseTapped,
                    onAssistantFollowUp: onAssistantFollowUp
                )
            )
        }
        assistantVisibilityCancellable = assistantSession.$phase
            .map { $0 != .inactive }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isAssistantVisible in
                self?.updateKeyFocus(
                    for: isAssistantVisible ? .assistant : .active
                )
            }
    }

    func show() {
        if panel == nil { initializeWindow() }
        panel?.show()
        updateKeyFocus(for: assistantSession.isVisible ? .assistant : .active)
    }

    func hide() {
        panel?.resignKey()
        panel?.orderOut(nil)
    }

    func destroyWindow() {
        deinitializeWindow()
    }

    private func initializeWindow() {
        deinitializeWindow()
        let metrics = NotchRecorderPanel.calculateWindowMetrics()
        let newPanel = NotchRecorderPanel(contentRect: metrics.frame)
        let view = makeView()
        let hostingController = NotchRecorderHostingController(rootView: view)
        newPanel.contentView = hostingController.view
        panel = newPanel
        windowController = NSWindowController(window: newPanel)
    }

    private func deinitializeWindow() {
        panel?.resignKey()
        panel?.orderOut(nil)
        windowController?.close()
        windowController = nil
        panel = nil
    }

    private func updateKeyFocus(for displayState: NotchPanelDisplayState) {
        guard let panel, panel.isVisible else { return }
        if displayState.wantsKeyFocus {
            panel.makeKeyAndOrderFront(nil)
        } else if panel.isKeyWindow {
            panel.resignKey()
        }
    }

}
