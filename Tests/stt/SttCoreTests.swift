import Foundation
import Testing
@testable import macSTT

private let testDefaultsKeys = [
    "stt.language",
    "stt.triggers",
    "stt.mouseButton",
    "stt.pendingTranscript",
    "stt.accessibilityPrompted",
]

private final class SttEnvironmentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: PermissionSnapshot
    private var pendingTranscript: PendingTranscript?
    private var typedTexts: [String] = []

    init(snapshot: PermissionSnapshot, pendingTranscript: PendingTranscript? = nil) {
        self.snapshot = snapshot
        self.pendingTranscript = pendingTranscript
    }

    func currentSnapshot() -> PermissionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func loadPendingTranscript() -> PendingTranscript? {
        lock.lock()
        defer { lock.unlock() }
        return pendingTranscript
    }

    func savePendingTranscript(_ pendingTranscript: PendingTranscript?) {
        lock.lock()
        self.pendingTranscript = pendingTranscript
        lock.unlock()
    }

    func recordTypedText(_ text: String) {
        lock.lock()
        typedTexts.append(text)
        lock.unlock()
    }

    func typedTextsSnapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return typedTexts
    }
}

private actor BatchTranscriptionBox {
    private var result: Result<String, Error>
    private var callCount = 0
    private var lastSampleCount = 0

    init(result: Result<String, Error>) {
        self.result = result
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        callCount += 1
        lastSampleCount = samples.count
        return try result.get()
    }

    func snapshot() -> (callCount: Int, lastSampleCount: Int) {
        return (callCount, lastSampleCount)
    }
}

private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let suiteName = "macSTTTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    try body(defaults)
}

@Test func sttActorStartsIdle() async {
    let actor = SttActor()
    let status = await actor.currentStatus
    #expect(status == .idle(detail: "Waiting to prepare"))
}

@Test func sttConfigRoundTripsCurrentValues() throws {
    try withIsolatedDefaults { defaults in
        testDefaultsKeys.forEach(defaults.removeObject(forKey:))

        let config = SttConfig(
            language: .multilingual,
            triggers: [
                .keyboard(keyCode: 126, modifiers: 0xC0000),
                .mouseButton(3),
            ]
        )

        try config.save(defaults: defaults)
        let loaded = SttConfig.load(defaults: defaults)

        #expect(loaded.language == .multilingual)
        #expect(
            loaded.triggers == [
                .keyboard(keyCode: 126, modifiers: 0xC0000),
                .mouseButton(3),
            ]
        )
    }
}

@Test func sttConfigDropsCorruptedTriggerPayloadAndRecovers() {
    withIsolatedDefaults { defaults in
        let fallbackTriggers = SttConfig.load(defaults: defaults).triggers
        defaults.set(SttLanguage.multilingual.rawValue, forKey: "stt.language")
        let brokenPayload = Data("broken".utf8)
        defaults.set(brokenPayload, forKey: "stt.triggers")

        let loaded = SttConfig.load(defaults: defaults)

        #expect(loaded.language == .multilingual)
        #expect(loaded.triggers == fallbackTriggers)
        #expect(defaults.data(forKey: "stt.triggers") != brokenPayload)
    }
}

@Test func sttConfigMigratesLegacyMouseTrigger() {
    withIsolatedDefaults { defaults in
        let fallbackTriggers = SttConfig.load(defaults: defaults).triggers
        defaults.set(4, forKey: "stt.mouseButton")

        let loaded = SttConfig.load(defaults: defaults)

        #expect(loaded.triggers == fallbackTriggers + [.mouseButton(4)])
        #expect(defaults.object(forKey: "stt.mouseButton") == nil)
        #expect(defaults.data(forKey: "stt.triggers") != nil)
    }
}

@Test func captureStopReasonOnlyFinalizesOnExplicitStop() {
    #expect(CaptureStopReason.userStop.finalizesTranscript == true)
    #expect(CaptureStopReason.internalRestart.finalizesTranscript == false)
    #expect(CaptureStopReason.shutdown.finalizesTranscript == false)
    #expect(CaptureStopReason.languageSwitch.finalizesTranscript == false)
}

@Test func triggerBindingDisplayNameFormatsKeyboardAndMouseTriggers() {
    #expect(TriggerBinding.keyboard(keyCode: 126, modifiers: 0xC0000).displayName == "⌃⌥↑")
    #expect(TriggerBinding.mouseButton(3).displayName == "Mouse 3")
}

@Test func permissionStateDisplayNamesCoverAllVisibleStates() {
    #expect(PermissionState.granted.displayName == "Granted")
    #expect(PermissionState.notDetermined.displayName == "Not Requested")
    #expect(PermissionState.denied.displayName == "Denied")
}

@Test func permissionSnapshotRequiresVisiblePermissions() {
    #expect(
        PermissionSnapshot(
            microphone: .granted,
            accessibility: .granted
        ).allGranted == true
    )
    #expect(
        PermissionSnapshot(
            microphone: .granted,
            accessibility: .denied
        ).allGranted == false
    )
}

@Test func sttStatusPresentationFormatsDownloadProgress() {
    let presentation = SttStatus.preparing(
        .downloadingModels(language: .english, completedFiles: 2, totalFiles: 5)
    ).presentation

    #expect(presentation.title == "Downloading Models")
    #expect(presentation.detail == "English model • 2/5 files")
    #expect(presentation.progressPercent == 36)
    #expect(presentation.showsProgress == true)
    #expect(presentation.isProgressIndeterminate == false)
}

@Test func sttStatusPresentationFormatsReadyState() {
    let presentation = SttStatus.ready.presentation

    #expect(presentation.title == "Ready")
    #expect(presentation.detail == nil)
    #expect(presentation.progressPercent == nil)
    #expect(presentation.showsProgress == false)
}

@Test func pendingTranscriptStoreRoundTripsAndClears() {
    withIsolatedDefaults { defaults in
        let pendingTranscript = PendingTranscript(
            text: "hello world",
            failureReason: "Accessibility permission is required."
        )

        PendingTranscriptStore.save(pendingTranscript, defaults: defaults)
        #expect(PendingTranscriptStore.load(defaults: defaults) == pendingTranscript)

        PendingTranscriptStore.clear(defaults: defaults)
        #expect(PendingTranscriptStore.load(defaults: defaults) == nil)
    }
}

@Test func sttActorBlocksCaptureWhenPermissionsAreMissing() async {
    let environmentBox = SttEnvironmentBox(
        snapshot: PermissionSnapshot(microphone: .granted, accessibility: .denied)
    )
    let actor = SttActor(
        environment: SttEnvironment(
            permissionSnapshot: { environmentBox.currentSnapshot() },
            requestMicrophonePermission: { false },
            promptAccessibilityPermission: {},
            typeTextAtCursor: { _ in },
            loadPendingTranscript: { environmentBox.loadPendingTranscript() },
            savePendingTranscript: { environmentBox.savePendingTranscript($0) }
        )
    )

    let result = await actor.beginCapture()

    #expect(result == .blockedByPermissions)
    #expect(await actor.isCurrentlyCapturing == false)
}

@Test func sttActorTriggerToggleReportsBlockedPermissions() async {
    let environmentBox = SttEnvironmentBox(
        snapshot: PermissionSnapshot(microphone: .granted, accessibility: .denied)
    )
    let actor = SttActor(
        environment: SttEnvironment(
            permissionSnapshot: { environmentBox.currentSnapshot() },
            requestMicrophonePermission: { false },
            promptAccessibilityPermission: {},
            typeTextAtCursor: { _ in },
            loadPendingTranscript: { environmentBox.loadPendingTranscript() },
            savePendingTranscript: { environmentBox.savePendingTranscript($0) }
        )
    )

    let result = await actor.toggleCaptureFromTrigger()

    #expect(result == .blockedByPermissions)
    #expect(await actor.isCurrentlyCapturing == false)
}

@Test func sttActorStoresPendingTranscriptWhenTypingFails() async {
    let environmentBox = SttEnvironmentBox(
        snapshot: PermissionSnapshot(microphone: .granted, accessibility: .granted)
    )
    let actor = SttActor(
        environment: SttEnvironment(
            permissionSnapshot: { environmentBox.currentSnapshot() },
            requestMicrophonePermission: { true },
            promptAccessibilityPermission: {},
            typeTextAtCursor: { _ in throw SyntheticTypingError.accessibilityNotGranted },
            loadPendingTranscript: { environmentBox.loadPendingTranscript() },
            savePendingTranscript: { environmentBox.savePendingTranscript($0) }
        )
    )

    await actor.commitTranscription("Recovered transcript")

    let expected = PendingTranscript(
        text: "Recovered transcript",
        failureReason: SyntheticTypingError.accessibilityNotGranted.errorDescription ?? ""
    )

    #expect(await actor.currentPendingTranscript == expected)
    #expect(environmentBox.loadPendingTranscript() == expected)

    await actor.dismissPendingTranscript()

    #expect(await actor.currentPendingTranscript == nil)
    #expect(environmentBox.loadPendingTranscript() == nil)
}

@Test func sttActorBatchFinalizeTranscribesCapturedSamplesOnce() async {
    let environmentBox = SttEnvironmentBox(
        snapshot: PermissionSnapshot(microphone: .granted, accessibility: .granted)
    )
    let transcriptionBox = BatchTranscriptionBox(result: .success("Batch transcript"))
    let actor = SttActor(
        environment: SttEnvironment(
            permissionSnapshot: { environmentBox.currentSnapshot() },
            requestMicrophonePermission: { true },
            promptAccessibilityPermission: {},
            typeTextAtCursor: { environmentBox.recordTypedText($0) },
            loadPendingTranscript: { environmentBox.loadPendingTranscript() },
            savePendingTranscript: { environmentBox.savePendingTranscript($0) },
            transcribeCapturedSamples: { samples in
                try await transcriptionBox.transcribe(samples)
            }
        )
    )

    await actor.appendCapturedSamplesForTesting(Array(repeating: 0.25, count: 16_000))
    await actor.finalizeCapturedAudioForTesting(reason: .userStop)

    let transcription = await transcriptionBox.snapshot()
    #expect(transcription.callCount == 1)
    #expect(transcription.lastSampleCount == 16_000)
    #expect(environmentBox.typedTextsSnapshot() == ["Batch transcript"])
    #expect(await actor.currentPendingTranscript == nil)
}

@Test func sttActorBatchFinalizesShortRecordingsWhenAudioExists() async {
    let environmentBox = SttEnvironmentBox(
        snapshot: PermissionSnapshot(microphone: .granted, accessibility: .granted)
    )
    let transcriptionBox = BatchTranscriptionBox(result: .success("Short transcript"))
    let actor = SttActor(
        environment: SttEnvironment(
            permissionSnapshot: { environmentBox.currentSnapshot() },
            requestMicrophonePermission: { true },
            promptAccessibilityPermission: {},
            typeTextAtCursor: { environmentBox.recordTypedText($0) },
            loadPendingTranscript: { environmentBox.loadPendingTranscript() },
            savePendingTranscript: { environmentBox.savePendingTranscript($0) },
            transcribeCapturedSamples: { samples in
                try await transcriptionBox.transcribe(samples)
            }
        )
    )

    await actor.appendCapturedSamplesForTesting(Array(repeating: 0.25, count: 15_999))
    await actor.finalizeCapturedAudioForTesting(reason: .userStop)

    let transcription = await transcriptionBox.snapshot()
    #expect(transcription.callCount == 1)
    #expect(transcription.lastSampleCount == 15_999)
    #expect(environmentBox.typedTextsSnapshot() == ["Short transcript"])
    #expect(await actor.currentPendingTranscript == nil)
}

@Test func sttActorSkipsBatchTranscriptionWhenNoAudioWasCaptured() async {
    let environmentBox = SttEnvironmentBox(
        snapshot: PermissionSnapshot(microphone: .granted, accessibility: .granted)
    )
    let transcriptionBox = BatchTranscriptionBox(result: .success("Should not run"))
    let actor = SttActor(
        environment: SttEnvironment(
            permissionSnapshot: { environmentBox.currentSnapshot() },
            requestMicrophonePermission: { true },
            promptAccessibilityPermission: {},
            typeTextAtCursor: { environmentBox.recordTypedText($0) },
            loadPendingTranscript: { environmentBox.loadPendingTranscript() },
            savePendingTranscript: { environmentBox.savePendingTranscript($0) },
            transcribeCapturedSamples: { samples in
                try await transcriptionBox.transcribe(samples)
            }
        )
    )

    await actor.finalizeCapturedAudioForTesting(reason: .userStop)

    let transcription = await transcriptionBox.snapshot()
    #expect(transcription.callCount == 0)
    #expect(environmentBox.typedTextsSnapshot().isEmpty)
    #expect(await actor.currentPendingTranscript == nil)
}

@Test func sttActorStoresPendingTranscriptWhenBatchTypingFails() async {
    let environmentBox = SttEnvironmentBox(
        snapshot: PermissionSnapshot(microphone: .granted, accessibility: .granted)
    )
    let transcriptionBox = BatchTranscriptionBox(result: .success("Recovered transcript"))
    let actor = SttActor(
        environment: SttEnvironment(
            permissionSnapshot: { environmentBox.currentSnapshot() },
            requestMicrophonePermission: { true },
            promptAccessibilityPermission: {},
            typeTextAtCursor: { _ in throw SyntheticTypingError.accessibilityNotGranted },
            loadPendingTranscript: { environmentBox.loadPendingTranscript() },
            savePendingTranscript: { environmentBox.savePendingTranscript($0) },
            transcribeCapturedSamples: { samples in
                try await transcriptionBox.transcribe(samples)
            }
        )
    )

    await actor.appendCapturedSamplesForTesting(Array(repeating: 0.25, count: 16_000))
    await actor.finalizeCapturedAudioForTesting(reason: .userStop)

    let transcription = await transcriptionBox.snapshot()
    let expected = PendingTranscript(
        text: "Recovered transcript",
        failureReason: SyntheticTypingError.accessibilityNotGranted.errorDescription ?? ""
    )

    #expect(transcription.callCount == 1)
    #expect(await actor.currentPendingTranscript == expected)
    #expect(environmentBox.loadPendingTranscript() == expected)
}

@Test func sttActorRetainsCapturedSamplesAcrossInternalRestart() async {
    let environmentBox = SttEnvironmentBox(
        snapshot: PermissionSnapshot(microphone: .granted, accessibility: .granted)
    )
    let transcriptionBox = BatchTranscriptionBox(result: .success("Restarted transcript"))
    let actor = SttActor(
        environment: SttEnvironment(
            permissionSnapshot: { environmentBox.currentSnapshot() },
            requestMicrophonePermission: { true },
            promptAccessibilityPermission: {},
            typeTextAtCursor: { environmentBox.recordTypedText($0) },
            loadPendingTranscript: { environmentBox.loadPendingTranscript() },
            savePendingTranscript: { environmentBox.savePendingTranscript($0) },
            transcribeCapturedSamples: { samples in
                try await transcriptionBox.transcribe(samples)
            }
        )
    )

    await actor.appendCapturedSamplesForTesting(Array(repeating: 0.25, count: 16_000))
    await actor.finalizeCapturedAudioForTesting(reason: .internalRestart)
    #expect(await actor.capturedSamplesCountForTesting == 16_000)

    await actor.appendCapturedSamplesForTesting(Array(repeating: 0.25, count: 4_000))
    await actor.finalizeCapturedAudioForTesting(reason: .userStop)

    let transcription = await transcriptionBox.snapshot()
    #expect(transcription.callCount == 1)
    #expect(transcription.lastSampleCount == 20_000)
    #expect(environmentBox.typedTextsSnapshot() == ["Restarted transcript"])
}
