import Foundation

@MainActor
class ModeShortcutManager {
    private let shortcutMonitor = ShortcutMonitor()
    private let modeProvider: @MainActor () -> RecordingShortcutManager.Mode
    private let shouldUsePushToTalk: @MainActor () -> Bool
    private let shortcutModeHandler: RecordingShortcutModeHandler
    private var shortcutChangeObserver: NSObjectProtocol?

    init(
        modeProvider: @escaping @MainActor () -> RecordingShortcutManager.Mode,
        shouldUsePushToTalk: @escaping @MainActor () -> Bool = { false },
        shortcutModeHandler: RecordingShortcutModeHandler
    ) {
        self.modeProvider = modeProvider
        self.shouldUsePushToTalk = shouldUsePushToTalk
        self.shortcutModeHandler = shortcutModeHandler

        refreshModeShortcuts()

        shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: ShortcutStore.shortcutDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let action = notification.object as? ShortcutAction,
                case .mode = action
            else {
                return
            }

            Task { @MainActor in
                self?.refreshModeShortcuts()
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(modeShortcutAvailabilityDidChange),
            name: .modeShortcutAvailabilityDidChange,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        if let shortcutChangeObserver {
            NotificationCenter.default.removeObserver(shortcutChangeObserver)
        }
        MainActor.assumeIsolated {
            shortcutMonitor.stop()
        }
    }

    @objc private func modeShortcutAvailabilityDidChange() {
        Task { @MainActor in
            refreshModeShortcuts()
        }
    }

    private func refreshModeShortcuts() {
        let shortcuts = ModeManager.shared.enabledConfigurations.reduce(into: [ShortcutAction: Shortcut]()) { result, config in
            let action = ShortcutAction.mode(config.id)
            if let shortcut = ShortcutStore.shortcut(for: action) {
                result[action] = shortcut
            }
        }

        shortcutMonitor.start(
            shortcuts: shortcuts,
            interruptibleActions: Set(shortcuts.keys),
            onKeyDown: { [weak self] action, eventTime in
                Task { @MainActor in
                    guard let self,
                          let modeId = self.modeId(for: action) else {
                        return
                    }

                    await self.shortcutModeHandler.handleKeyDown(
                        action: action,
                        eventTime: eventTime,
                        mode: self.effectiveMode,
                        modeId: modeId
                    )
                }
            },
            onKeyUp: { [weak self] action, eventTime in
                Task { @MainActor in
                    guard let self,
                          case .mode(let modeId) = action else {
                        return
                    }

                    NSLog("NINOKEY up mode=%@ pushToTalk=%@ modeId=%@",
                          String(describing: self.effectiveMode),
                          String(describing: self.shouldUsePushToTalk()),
                          modeId.uuidString)
                    await self.shortcutModeHandler.handleKeyUp(
                        action: action,
                        eventTime: eventTime,
                        mode: self.effectiveMode,
                        modeId: modeId
                    )
                }
            },
            onShortcutInterrupted: { [weak self] action, _ in
                Task { @MainActor in
                    guard let self, case .mode = action else { return }
                    await self.shortcutModeHandler.handleInterruption(action: action)
                }
            }
        )
    }

    private var effectiveMode: RecordingShortcutManager.Mode {
        shouldUsePushToTalk() ? .pushToTalk : modeProvider()
    }

    private func modeId(for action: ShortcutAction) -> UUID? {
        guard case .mode(let modeId) = action,
              let config = ModeManager.shared.getConfiguration(with: modeId),
              config.isEnabled,
              ShortcutStore.shortcut(for: .mode(config.id)) != nil else {
            return nil
        }

        return modeId
    }
}
