import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import VoiceInk

struct ShortcutMigrationTests {
    private let migrationKey = "Shortcut_NinoInterfaceKeyMapV2Migrated"

    @Test @MainActor func ninoInterfaceKeyMapMigrationMovesDefaultsPreservesCustomizationsAndIsIdempotent() {
        let defaults = UserDefaults.standard
        let migratedActions: [ShortcutAction] = [
            .primaryRecording,
            .assistantAsk,
            .handsFreeToggle,
            .pasteLastEnhancement
        ]
        var seenActions = Set<ShortcutAction>()
        let actions = (ShortcutAction.legacyKeyboardShortcutActions +
            ModeManager.shared.configurations.map { ShortcutAction.mode($0.id) })
            .filter { seenActions.insert($0).inserted }
        let keys = actions.flatMap { [$0.userDefaultsKey, "\($0.userDefaultsKey)_cleared"] } + [migrationKey]
        let originalValues = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })

        defer {
            for (key, value) in originalValues {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        func store(_ shortcut: Shortcut?, for action: ShortcutAction) {
            defaults.removeObject(forKey: "\(action.userDefaultsKey)_cleared")
            if let shortcut {
                defaults.set(try! JSONEncoder().encode(shortcut), forKey: action.userDefaultsKey)
            } else {
                defaults.removeObject(forKey: action.userDefaultsKey)
            }
        }

        let rightCommand = Shortcut.modifierOnly(
            keyCode: UInt16(kVK_RightCommand),
            modifierFlags: [.command]
        )
        let rightOption = Shortcut.modifierOnly(
            keyCode: UInt16(kVK_RightOption),
            modifierFlags: [.option]
        )
        let leftOption = Shortcut.modifierOnly(
            keyCode: UInt16(kVK_Option),
            modifierFlags: [.option]
        )
        let fn = Shortcut.modifierOnly(
            keyCode: UInt16(kVK_Function),
            modifierFlags: [.function]
        )

        for action in actions { store(nil, for: action) }
        defaults.removeObject(forKey: migrationKey)
        store(rightCommand, for: .primaryRecording)
        store(leftOption, for: .handsFreeToggle)
        store(fn, for: .pasteLastEnhancement)

        ShortcutMigration.migrateNinoInterfaceKeyMapIfNeeded()

        #expect(ShortcutStore.shortcut(for: .primaryRecording) == rightOption)
        #expect(ShortcutStore.shortcut(for: .assistantAsk) == rightCommand)
        #expect(ShortcutStore.shortcut(for: .pasteLastEnhancement) == leftOption)
        #expect(ShortcutStore.shortcut(for: .handsFreeToggle) == nil)

        let firstRunData = Dictionary(uniqueKeysWithValues: migratedActions.map { ($0, defaults.data(forKey: $0.userDefaultsKey)) })
        let firstRunCleared = Dictionary(uniqueKeysWithValues: migratedActions.map { ($0, defaults.bool(forKey: "\($0.userDefaultsKey)_cleared")) })
        ShortcutMigration.migrateNinoInterfaceKeyMapIfNeeded()
        for action in migratedActions {
            #expect(firstRunData[action] == defaults.data(forKey: action.userDefaultsKey))
            #expect(firstRunCleared[action] == defaults.bool(forKey: "\(action.userDefaultsKey)_cleared"))
        }

        for action in actions { store(nil, for: action) }
        defaults.removeObject(forKey: migrationKey)
        let customPrimary = Shortcut.key(keyCode: UInt16(kVK_ANSI_R), modifierFlags: [.control])
        store(customPrimary, for: .primaryRecording)
        store(leftOption, for: .handsFreeToggle)
        store(fn, for: .pasteLastEnhancement)

        ShortcutMigration.migrateNinoInterfaceKeyMapIfNeeded()

        #expect(ShortcutStore.shortcut(for: .primaryRecording) == customPrimary)
    }
}
