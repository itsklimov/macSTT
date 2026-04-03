import Foundation
import Logging

struct PendingTranscript: Codable, Equatable, Sendable {
    var text: String
    var failureReason: String
}

enum PendingTranscriptStore {
    private static let defaultsKey = "stt.pendingTranscript"
    private static let logger = Logger(label: "com.wixfi.stt.pending-transcript")

    static func load(defaults: UserDefaults = .standard) -> PendingTranscript? {
        guard let data = defaults.data(forKey: defaultsKey) else {
            return nil
        }

        do {
            return try JSONDecoder().decode(PendingTranscript.self, from: data)
        } catch {
            logger.error("Failed to decode pending transcript: \(error)")
            defaults.removeObject(forKey: defaultsKey)
            return nil
        }
    }

    static func save(_ pendingTranscript: PendingTranscript, defaults: UserDefaults = .standard) {
        do {
            let data = try JSONEncoder().encode(pendingTranscript)
            defaults.set(data, forKey: defaultsKey)
        } catch {
            logger.error("Failed to encode pending transcript: \(error)")
        }
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
