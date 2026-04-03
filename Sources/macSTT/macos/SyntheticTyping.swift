@preconcurrency import ApplicationServices
import CoreGraphics
import Logging

enum SyntheticTypingError: LocalizedError, Equatable {
    case accessibilityNotGranted
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            "Accessibility permission is required to type text at the current cursor."
        case .eventCreationFailed:
            "macSTT could not synthesize keyboard input."
        }
    }
}

enum SyntheticTyping {

    private static let logger = Logger(label: "com.wixfi.stt.typing")
    static let insertionVirtualKey: CGKeyCode = 0x31
    static let insertionTapLocation: CGEventTapLocation = .cgAnnotatedSessionEventTap
    static let insertionSetsUnicodeOnKeyUp = false

    static func promptAccessibilityPermission() {
        _ = CGRequestPostEventAccess()
    }

    static func requireAccessibilityPermission(
        isTrusted: () -> Bool = { CGPreflightPostEventAccess() },
        prompt: () -> Void = { promptAccessibilityPermission() }
    ) throws {
        guard isTrusted() else {
            logger.warning("Accessibility not granted, prompting user")
            prompt()
            throw SyntheticTypingError.accessibilityNotGranted
        }
    }

    static func utf16Chunks(for text: String, chunkSize: Int = 20) -> [[UInt16]] {
        guard chunkSize > 0 else { return [] }

        let utf16 = Array(text.utf16)
        return stride(from: 0, to: utf16.count, by: chunkSize).map { start in
            let end = min(start + chunkSize, utf16.count)
            return Array(utf16[start..<end])
        }
    }

    static func typeAtCursor(_ text: String) throws {
        try requireAccessibilityPermission()

        for var chunk in utf16Chunks(for: text) {
            guard let keyDown = CGEvent(
                keyboardEventSource: nil,
                virtualKey: Self.insertionVirtualKey,
                keyDown: true
            ), let keyUp = CGEvent(
                keyboardEventSource: nil,
                virtualKey: Self.insertionVirtualKey,
                keyDown: false
            )
            else {
                logger.error("Failed to create CGEvent")
                throw SyntheticTypingError.eventCreationFailed
            }

            keyDown.flags = .maskNonCoalesced
            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyDown.post(tap: Self.insertionTapLocation)

            keyUp.flags = .maskNonCoalesced
            keyUp.post(tap: Self.insertionTapLocation)
        }

        logger.info("Typed \(text.count) characters")
    }
}
