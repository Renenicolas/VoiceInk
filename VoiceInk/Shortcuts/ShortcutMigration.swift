import AppKit
import Carbon.HIToolbox
import Foundation

struct LegacyKeyboardShortcut: Codable {
    let carbonKeyCode: Int
    let carbonModifiers: Int
}

struct ShortcutBackup: Codable {
    let shortcut: Shortcut

    init(_ shortcut: Shortcut) {
        self.shortcut = shortcut
    }

    init(from decoder: Decoder) throws {
        if let shortcut = try? Shortcut(from: decoder) {
            self.shortcut = shortcut
            return
        }

        let legacyShortcut = try LegacyKeyboardShortcut(from: decoder)
        self.shortcut = Shortcut.fromLegacyShortcut(legacyShortcut)
    }

    func encode(to encoder: Encoder) throws {
        try shortcut.encode(to: encoder)
    }
}

enum ShortcutMigration {
    static func migrateLegacyShortcutsIfNeeded() {
        discardLegacyCustomRecordingShortcutsIfNeeded()
        migrateLegacyKeyboardShortcutsIfNeeded()
        migrateNinoInterfaceKeyMapIfNeeded()
    }

    /// Rene's key map, v3 (2026-08-27). Four keys, and Left-Control kept clear.
    ///
    ///   Right-Option     Dictation        raw transcript, no AI enhancement
    ///   Right-Command    Ask Nino         the notch
    ///   Command+Option   Enhancement      AI-enhanced, per-app learned voice
    ///   Left-Option      paste last enhancement
    ///   Left-Control     deliberately EMPTY
    ///
    /// Two earlier versions got this wrong and both mistakes are repaired here.
    /// v1 put `primaryRecording` on Right-Option, which records with whatever mode
    /// is ACTIVE — so it returned enhanced text whenever an enhancing mode was
    /// selected. v2 fixed that but left `primaryRecording` unbound entirely, which
    /// silently removed the key Rene had been holding to talk for months.
    ///
    /// KNOWN LIMIT, deliberate: the Command+Option chord cannot tell left from
    /// right. `Shortcut.shortcutRelevant` keeps only the generic .command/.option
    /// flags, not macOS's device-dependent left/right bits, so a chord shortcut is
    /// matched on the combination alone. Either side fires it. Adding side
    /// awareness means changing how every shortcut is matched, which is not worth
    /// the regression risk on a working app — and in practice a bare chord is
    /// harmless, because `isInterruptedByAdditionalKeyDown` cancels it the moment
    /// any real key joins, so Cmd+Opt+letter still reaches the front app.
    static func migrateNinoInterfaceKeyMapIfNeeded() {
        let migrationKey = "Shortcut_NinoInterfaceKeyMapV3Migrated"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        let rightCommand = Shortcut.modifierOnly(keyCode: UInt16(kVK_RightCommand), modifierFlags: [.command])
        let rightOption = Shortcut.modifierOnly(keyCode: UInt16(kVK_RightOption), modifierFlags: [.option])
        let leftOption = Shortcut.modifierOnly(keyCode: UInt16(kVK_Option), modifierFlags: [.option])
        let fn = Shortcut.modifierOnly(keyCode: UInt16(kVK_Function), modifierFlags: [.function])
        let commandOption = Shortcut.modifierOnly(keyCode: nil, modifierFlags: [.command, .option])

        let dictation = ShortcutAction.mode(StarterModeCatalog.dictationModeId)
        let enhancement = ShortcutAction.mode(StarterModeCatalog.enhancementModeId)
        let liveAnswers = ShortcutAction.mode(StarterModeCatalog.liveAnswersModeId)

        // v1 left this on Right-Option, where it enhanced whenever the active mode
        // did. It is not part of the map at all now: every recording key is a mode
        // key, so what you hold decides what you get, never the current selection.
        if ShortcutStore.shortcut(for: .primaryRecording) != nil {
            ShortcutStore.setShortcut(nil, for: .primaryRecording)
        }

        // Right-Option -> Dictation (raw).
        bind(dictation, to: rightOption)

        // Command+Option -> Enhancement (AI, per-app voice).
        bind(enhancement, to: commandOption)

        // Left-Control stays clear.
        if ShortcutStore.shortcut(for: liveAnswers) != nil {
            NSLog("Nino key map v3: unbound Answers Live, Left-Control is kept clear")
            ShortcutStore.setShortcut(nil, for: liveAnswers)
        }

        // Left-Option -> paste. Free it first; Fn is not on every keyboard.
        if ShortcutStore.shortcut(for: .handsFreeToggle) == leftOption {
            ShortcutStore.setShortcut(nil, for: .handsFreeToggle)
        }
        if ShortcutStore.shortcut(for: .pasteLastEnhancement) == fn {
            ShortcutStore.setShortcut(leftOption, for: .pasteLastEnhancement)
        }

        // Right-Command -> Ask Nino.
        bind(.assistantAsk, to: rightCommand)

        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    /// Put `action` on `shortcut`, clearing whatever else is sitting there first.
    /// Refuses only if the blocker is an action outside this map — those belong to
    /// the user and are never taken.
    private static func bind(_ action: ShortcutAction, to shortcut: Shortcut) {
        if ShortcutStore.shortcut(for: action) == shortcut { return }
        if let blocker = actionOccupying(shortcut, excluding: action) {
            guard Self.ninoMapActions.contains(blocker) else {
                NSLog("Nino key map v3: skipped %@, %@ is held by %@",
                      action.storageName, shortcut.displayString, blocker.storageName)
                return
            }
            ShortcutStore.setShortcut(nil, for: blocker)
        }
        ShortcutStore.setShortcut(shortcut, for: action)
    }

    /// The only actions this migration is allowed to move or clear.
    private static var ninoMapActions: [ShortcutAction] {
        [
            .primaryRecording,
            .handsFreeToggle,
            .pasteLastEnhancement,
            .assistantAsk,
            .mode(StarterModeCatalog.dictationModeId),
            .mode(StarterModeCatalog.enhancementModeId),
            .mode(StarterModeCatalog.liveAnswersModeId),
        ]
    }

    private static func moveShortcut(for action: ShortcutAction, from oldShortcut: Shortcut, to newShortcut: Shortcut) {
        guard ShortcutStore.shortcut(for: action) == oldShortcut else { return }
        guard actionOccupying(newShortcut, excluding: action) == nil else {
            NSLog("Nino shortcut migration skipped %@: %@ is already occupied", action.storageName, newShortcut.displayString)
            return
        }
        ShortcutStore.setShortcut(newShortcut, for: action)
    }

    private static func actionOccupying(_ shortcut: Shortcut, excluding excludedAction: ShortcutAction) -> ShortcutAction? {
        let storedActions = ShortcutAction.legacyKeyboardShortcutActions +
            ModeManager.shared.configurations.map { ShortcutAction.mode($0.id) }
        return storedActions.first {
            $0 != excludedAction && ShortcutStore.shortcut(for: $0)?.conflicts(with: shortcut) == true
        }
    }

    static func migrateLegacyKeyboardShortcutsIfNeeded() {
        let migrationKey = "Shortcut_LegacyKeyboardShortcutsMigrated"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return
        }

        for action in ShortcutAction.legacyKeyboardShortcutActions {
            migrateLegacyKeyboardShortcut(for: action)
        }

        for config in ModeManager.shared.configurations {
            migrateLegacyKeyboardShortcut(for: .mode(config.id))
        }

        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    static func migrateShortcutSelection(
        action: ShortcutAction,
        allowsNone: Bool
    ) -> RecordingShortcutManager.ShortcutSelection {
        let userDefaultsKey = recordingShortcutKey(for: action)
        let legacyKey = legacyRecordingShortcutKey(for: action)

        if let storedValue = nonEmptyString(forKey: userDefaultsKey) {
            return shortcutSelection(
                from: storedValue,
                savingTo: userDefaultsKey,
                removing: legacyKey,
                action: action,
                allowsNone: allowsNone
            )
        }

        if let legacyValue = nonEmptyString(forKey: legacyKey) {
            return shortcutSelection(
                from: legacyValue,
                savingTo: userDefaultsKey,
                removing: legacyKey,
                action: action,
                allowsNone: allowsNone
            )
        }

        if !allowsNone {
            return .custom
        }

        return .none
    }

    static func migrateShortcutMode(
        for action: ShortcutAction
    ) -> RecordingShortcutManager.Mode {
        let userDefaultsKey = recordingShortcutModeKey(for: action)
        let legacyKey = legacyRecordingShortcutModeKey(for: action)

        if let storedValue = nonEmptyString(forKey: userDefaultsKey),
           let mode = RecordingShortcutManager.Mode(rawValue: storedValue) {
            UserDefaults.standard.removeObject(forKey: legacyKey)
            return mode
        }

        if let legacyValue = nonEmptyString(forKey: legacyKey),
           let mode = RecordingShortcutManager.Mode(rawValue: legacyValue) {
            UserDefaults.standard.set(mode.rawValue, forKey: userDefaultsKey)
            UserDefaults.standard.removeObject(forKey: legacyKey)
            return mode
        }

        return .hybrid
    }

    private static func shortcutSelection(
        from storedValue: String,
        savingTo userDefaultsKey: String,
        removing legacyKey: String?,
        action: ShortcutAction,
        allowsNone: Bool
    ) -> RecordingShortcutManager.ShortcutSelection {
        if storedValue == RecordingShortcutManager.ShortcutSelection.custom.rawValue {
            saveShortcutSelection(.custom, forKey: userDefaultsKey, removing: legacyKey)
            return .custom
        }

        if storedValue == RecordingShortcutManager.ShortcutSelection.none.rawValue {
            let selection: RecordingShortcutManager.ShortcutSelection = allowsNone ? .none : .custom
            saveShortcutSelection(selection, forKey: userDefaultsKey, removing: legacyKey)
            return selection
        }

        if let shortcut = legacyPresetShortcut(for: storedValue),
           !isRecordingShortcutAction(action) {
            ShortcutStore.setShortcut(shortcut, for: action)
            saveShortcutSelection(.custom, forKey: userDefaultsKey, removing: legacyKey)
            return .custom
        }

        let selection: RecordingShortcutManager.ShortcutSelection = allowsNone ? .none : .custom
        saveShortcutSelection(selection, forKey: userDefaultsKey, removing: legacyKey)
        return selection
    }

    private static func saveShortcutSelection(
        _ selection: RecordingShortcutManager.ShortcutSelection,
        forKey userDefaultsKey: String,
        removing legacyKey: String?
    ) {
        UserDefaults.standard.set(selection.rawValue, forKey: userDefaultsKey)

        if let legacyKey {
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
    }

    static func removeLegacyCustomRecordingShortcut(for action: ShortcutAction) {
        UserDefaults.standard.removeObject(forKey: legacyCustomRecordingShortcutKey(for: action))
    }

    static func removeLegacyKeyboardShortcut(for action: ShortcutAction) {
        for legacyName in legacyKeyboardShortcutsNames(for: action) {
            UserDefaults.standard.removeObject(forKey: "KeyboardShortcuts_\(legacyName)")
        }
    }

    static func migrateLegacyKeyboardShortcut(for action: ShortcutAction) {
        defer {
            removeLegacyKeyboardShortcut(for: action)
        }

        guard !isRecordingShortcutAction(action) else {
            return
        }

        guard
            ShortcutStore.rawShortcut(for: action) == nil,
            !ShortcutStore.isShortcutCleared(for: action),
            let shortcut = legacyKeyboardShortcut(for: action)
        else {
            return
        }

        ShortcutStore.setShortcut(shortcut, for: action)
    }

    private static func discardLegacyCustomRecordingShortcutsIfNeeded() {
        let migrationKey = "Shortcut_LegacyCustomRecordingShortcutsMigrated"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return
        }

        for action in [ShortcutAction.primaryRecording, .secondaryRecording] {
            removeLegacyCustomRecordingShortcut(for: action)
        }

        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    private static func legacyPresetShortcut(for rawValue: String) -> Shortcut? {
        switch rawValue {
        case "rightOption":
            return .modifierOnly(keyCode: UInt16(kVK_RightOption), modifierFlags: [.option])
        case "leftOption":
            return .modifierOnly(keyCode: UInt16(kVK_Option), modifierFlags: [.option])
        case "leftControl":
            return .modifierOnly(keyCode: UInt16(kVK_Control), modifierFlags: [.control])
        case "rightControl":
            return .modifierOnly(keyCode: UInt16(kVK_RightControl), modifierFlags: [.control])
        case "fn":
            return .modifierOnly(keyCode: UInt16(kVK_Function), modifierFlags: [.function])
        case "rightCommand":
            return .modifierOnly(keyCode: UInt16(kVK_RightCommand), modifierFlags: [.command])
        case "rightShift":
            return .modifierOnly(keyCode: UInt16(kVK_RightShift), modifierFlags: [.shift])
        default:
            return nil
        }
    }

    private static func isRecordingShortcutAction(_ action: ShortcutAction) -> Bool {
        switch action {
        case .primaryRecording, .secondaryRecording:
            return true
        default:
            return false
        }
    }

    private static func legacyCustomRecordingShortcutKey(for action: ShortcutAction) -> String {
        switch action {
        case .primaryRecording:
            return "CustomRecordingShortcut_primary"
        case .secondaryRecording:
            return "CustomRecordingShortcut_secondary"
        default:
            return "CustomRecordingShortcut_\(action.storageName)"
        }
    }

    private static func legacyKeyboardShortcut(for action: ShortcutAction) -> Shortcut? {
        guard
            let legacyName = legacyKeyboardShortcutsNames(for: action).first(where: {
                UserDefaults.standard.string(forKey: "KeyboardShortcuts_\($0)") != nil
            }),
            let data = UserDefaults.standard.string(forKey: "KeyboardShortcuts_\(legacyName)")?.data(using: .utf8),
            let legacyShortcut = try? JSONDecoder().decode(LegacyKeyboardShortcut.self, from: data)
        else {
            return nil
        }

        return Shortcut.fromLegacyShortcut(legacyShortcut)
    }

    private static func legacyKeyboardShortcutsNames(for action: ShortcutAction) -> [String] {
        switch action {
        case .primaryRecording:
            return ["toggleMiniRecorder"]
        case .secondaryRecording:
            return ["toggleMiniRecorder2"]
        case .handsFreeToggle:
            return []
        case .assistantAsk:
            return []
        case .pasteLastTranscription:
            return ["pasteLastTranscription"]
        case .pasteLastEnhancement:
            return ["pasteLastEnhancement"]
        case .retryLastTranscription:
            return ["retryLastTranscription"]
        case .cancelRecorder:
            return ["cancelRecorder"]
        case .openHistoryWindow:
            return ["openHistoryWindow"]
        case .quickAddToDictionary:
            return ["quickAddToDictionary"]
        case .mode(let id):
            return ["mode_\(id.uuidString)", "powerMode_\(id.uuidString)"]
        case .recorderPanelEscape, .recorderPanelMode:
            return []
        }
    }

    private static func recordingShortcutKey(for action: ShortcutAction) -> String {
        switch action {
        case .primaryRecording:
            return "primaryRecordingShortcut"
        case .secondaryRecording:
            return "secondaryRecordingShortcut"
        default:
            return action.userDefaultsKey
        }
    }

    private static func legacyRecordingShortcutKey(for action: ShortcutAction) -> String {
        switch action {
        case .primaryRecording:
            return "selectedHotkey1"
        case .secondaryRecording:
            return "selectedHotkey2"
        default:
            return action.userDefaultsKey
        }
    }

    private static func recordingShortcutModeKey(for action: ShortcutAction) -> String {
        switch action {
        case .primaryRecording:
            return "primaryRecordingShortcutMode"
        case .secondaryRecording:
            return "secondaryRecordingShortcutMode"
        default:
            return action.userDefaultsKey
        }
    }

    private static func legacyRecordingShortcutModeKey(for action: ShortcutAction) -> String {
        switch action {
        case .primaryRecording:
            return "hotkeyMode1"
        case .secondaryRecording:
            return "hotkeyMode2"
        default:
            return action.userDefaultsKey
        }
    }

    private static func nonEmptyString(forKey key: String) -> String? {
        guard
            let value = UserDefaults.standard.string(forKey: key),
            !value.isEmpty
        else {
            return nil
        }

        return value
    }
}
