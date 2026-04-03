import Foundation
import KeyboardShortcuts
import Logging

// Retained for migration from old UserDefaults format
extension KeyboardShortcuts.Name {
    static let toggleSttCapture = Self("toggleSttCapture", default: .init(.s, modifiers: [.control, .option]))
}

enum SttLanguage: String, Sendable, CaseIterable {
    case english
    case multilingual

    var displayName: String {
        switch self {
        case .english:
            "English"
        case .multilingual:
            "Multilingual"
        }
    }
}

enum SttConfigError: LocalizedError {
    case encodeTriggersFailed(Error)

    var errorDescription: String? {
        switch self {
        case .encodeTriggersFailed:
            "Failed to save trigger settings."
        }
    }
}

struct SttConfig: Sendable {
    var language: SttLanguage
    var triggers: [TriggerBinding]

    private static let logger = Logger(label: "com.wixfi.stt.config")
    private static let languageKey = "stt.language"
    private static let triggersKey = "stt.triggers"
    private static let mouseButtonKey = "stt.mouseButton"

    static func load(defaults: UserDefaults = .standard) -> SttConfig {
        return SttConfig(
            language: SttLanguage(rawValue: defaults.string(forKey: languageKey) ?? "") ?? .english,
            triggers: loadTriggers(defaults: defaults)
        )
    }

    func save(defaults: UserDefaults = .standard) throws {
        let triggerData: Data
        do {
            triggerData = try JSONEncoder().encode(triggers)
        } catch {
            Self.logger.error("Failed to encode trigger config: \(error)")
            throw SttConfigError.encodeTriggersFailed(error)
        }

        defaults.set(language.rawValue, forKey: Self.languageKey)
        defaults.set(triggerData, forKey: Self.triggersKey)
    }

    private static func loadTriggers(defaults: UserDefaults) -> [TriggerBinding] {
        if let data = defaults.data(forKey: triggersKey) {
            do {
                let decodedTriggers = try JSONDecoder().decode([TriggerBinding].self, from: data)
                return mergeLegacyMouseTrigger(into: decodedTriggers, defaults: defaults)
            } catch {
                logger.error("Failed to decode trigger config: \(error)")
                defaults.removeObject(forKey: triggersKey)
            }
        }
        return migrateOldTriggers(defaults: defaults)
    }

    private static func mergeLegacyMouseTrigger(into triggers: [TriggerBinding], defaults: UserDefaults) -> [TriggerBinding] {
        guard let button = defaults.object(forKey: mouseButtonKey) as? Int else {
            return triggers
        }

        let mouseTrigger = TriggerBinding.mouseButton(button)
        guard !triggers.contains(mouseTrigger) else {
            defaults.removeObject(forKey: mouseButtonKey)
            return triggers
        }

        let mergedTriggers = triggers + [mouseTrigger]
        do {
            let data = try JSONEncoder().encode(mergedTriggers)
            defaults.set(data, forKey: triggersKey)
            defaults.removeObject(forKey: mouseButtonKey)
        } catch {
            logger.error("Failed to merge legacy mouse trigger: \(error)")
        }
        return mergedTriggers
    }

    private static func migrateOldTriggers(defaults: UserDefaults) -> [TriggerBinding] {
        var triggers: [TriggerBinding] = []

        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleSttCapture),
           let key = shortcut.key {
            let modifiers = UInt(shortcut.modifiers.rawValue) & TriggerBinding.modifierMask
            triggers.append(.keyboard(keyCode: key.rawValue, modifiers: modifiers))
        }

        let legacyMouseButton = defaults.object(forKey: mouseButtonKey) as? Int
        if let button = legacyMouseButton {
            triggers.append(.mouseButton(button))
        }

        if !triggers.isEmpty {
            do {
                let data = try JSONEncoder().encode(triggers)
                defaults.set(data, forKey: triggersKey)
                if legacyMouseButton != nil {
                    defaults.removeObject(forKey: mouseButtonKey)
                }
            } catch {
                logger.error("Failed to persist migrated triggers: \(error)")
            }
        }

        return triggers
    }
}
