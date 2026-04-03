@preconcurrency import ApplicationServices
@preconcurrency import AVFoundation
import CoreAudio
@preconcurrency import CoreML
@preconcurrency import FluidAudio
import Foundation
import Logging

extension SttLanguage {
    var modelVersion: AsrModelVersion {
        switch self {
        case .english: .v2
        case .multilingual: .v3
        }
    }

    var repo: Repo {
        switch self {
        case .english: .parakeetV2
        case .multilingual: .parakeet
        }
    }
}

enum CaptureAttemptResult: Sendable, Equatable {
    case started
    case blockedByPermissions
    case ignored
}

enum CaptureToggleResult: Sendable, Equatable {
    case started
    case stopped
    case blockedByPermissions
    case ignored
}

private enum PermissionAccess {
    private static let inputMonitoringPromptedKey = "stt.inputMonitoringPrompted"
    private static let accessibilityPromptedKey = "stt.accessibilityPrompted"

    static func snapshot(defaults: UserDefaults = .standard) -> PermissionSnapshot {
        PermissionSnapshot(
            microphone: microphoneStatus(),
            inputMonitoring: inputMonitoringStatus(defaults: defaults),
            accessibility: accessibilityStatus(defaults: defaults)
        )
    }

    static func microphoneStatus() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            .granted
        case .notDetermined:
            .notDetermined
        case .denied, .restricted:
            .denied
        @unknown default:
            .denied
        }
    }

    static func accessibilityStatus(defaults: UserDefaults = .standard) -> PermissionState {
        if CGPreflightPostEventAccess() {
            return .granted
        }

        return defaults.bool(forKey: accessibilityPromptedKey) ? .denied : .notDetermined
    }

    static func inputMonitoringStatus(defaults: UserDefaults = .standard) -> PermissionState {
        if CGPreflightListenEventAccess() {
            return .granted
        }

        return defaults.bool(forKey: inputMonitoringPromptedKey) ? .denied : .notDetermined
    }

    static func promptInputMonitoring(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: inputMonitoringPromptedKey)
        _ = CGRequestListenEventAccess()
    }

    static func promptAccessibility(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: accessibilityPromptedKey)
        SyntheticTyping.promptAccessibilityPermission()
    }
}

struct SttEnvironment: Sendable {
    var permissionSnapshot: @Sendable () -> PermissionSnapshot
    var requestMicrophonePermission: @Sendable () async -> Bool
    var promptInputMonitoringPermission: @Sendable () -> Void
    var promptAccessibilityPermission: @Sendable () -> Void
    var typeTextAtCursor: @Sendable (String) throws -> Void
    var loadPendingTranscript: @Sendable () -> PendingTranscript?
    var savePendingTranscript: @Sendable (PendingTranscript?) -> Void
    var transcribeCapturedSamples: (@Sendable ([Float]) async throws -> String)? = nil

    static let live = SttEnvironment(
        permissionSnapshot: { PermissionAccess.snapshot() },
        requestMicrophonePermission: {
            await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        },
        promptInputMonitoringPermission: { PermissionAccess.promptInputMonitoring() },
        promptAccessibilityPermission: { PermissionAccess.promptAccessibility() },
        typeTextAtCursor: { try SyntheticTyping.typeAtCursor($0) },
        loadPendingTranscript: { PendingTranscriptStore.load() },
        savePendingTranscript: { pendingTranscript in
            if let pendingTranscript {
                PendingTranscriptStore.save(pendingTranscript)
            } else {
                PendingTranscriptStore.clear()
            }
        }
    )
}

enum CaptureStopReason: Sendable {
    case userStop
    case internalRestart
    case shutdown
    case languageSwitch

    var finalizesTranscript: Bool {
        self == .userStop
    }

    var description: String {
        switch self {
        case .userStop:
            "user stop"
        case .internalRestart:
            "internal restart"
        case .shutdown:
            "shutdown"
        case .languageSwitch:
            "language switch"
        }
    }
}

private enum FeedbackSound: String, CaseIterable {
    case captureStarted = "Glass"
    case captureRejected = "Basso"

    var fileURL: URL {
        URL(fileURLWithPath: "/System/Library/Sounds/\(rawValue).aiff")
    }
}

private final class FeedbackSoundPlayer {
    private let logger = Logger(label: "com.wixfi.stt.sound-feedback")
    private var players: [FeedbackSound: AVAudioPlayer] = [:]

    func prepare() {
        FeedbackSound.allCases.forEach { _ = player(for: $0) }
    }

    func play(_ sound: FeedbackSound) {
        guard let player = player(for: sound) else { return }
        player.stop()
        player.currentTime = 0
        player.play()
    }

    private func player(for sound: FeedbackSound) -> AVAudioPlayer? {
        if let existing = players[sound] {
            return existing
        }

        do {
            let player = try AVAudioPlayer(contentsOf: sound.fileURL)
            player.volume = 0.33
            player.prepareToPlay()
            players[sound] = player
            return player
        } catch {
            logger.error("Failed to initialize \(sound.rawValue) feedback sound: \(error)")
            return nil
        }
    }
}

private actor BatchAsrRuntime {
    private let manager = AsrManager()

    func loadModels(_ models: AsrModels) async throws {
        try await manager.loadModels(models)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let result = try await manager.transcribe(samples, source: .microphone)
        return result.text
    }

    func cleanup() async {
        await manager.cleanup()
    }
}

actor SttActor {
    // 512 frames keeps callback cadence close to 10 ms on 48 kHz input without pushing CPU too hard.
    private static let captureTapBufferSize: AVAudioFrameCount = 512

    private enum CaptureMode: Sendable, Equatable {
        case idle
        case capturing
        case finalizingUserStop
    }

    private struct FinalizedCaptureBatch: Sendable {
        let samples: [Float]
        let backend: SttModelBackend
    }

    let statusUpdates: AsyncStream<SttStatus>
    let permissionUpdates: AsyncStream<PermissionSnapshot>
    let pendingTranscriptUpdates: AsyncStream<PendingTranscript?>

    private let logger = Logger(label: "com.wixfi.stt.stt")
    private let monitor: AudioDeviceMonitor
    private let audioConverter = AudioConverter()
    private let batchAsrRuntime = BatchAsrRuntime()
    private let feedbackSoundPlayer = FeedbackSoundPlayer()
    private let statusContinuation: AsyncStream<SttStatus>.Continuation
    private let permissionContinuation: AsyncStream<PermissionSnapshot>.Continuation
    private let pendingTranscriptContinuation: AsyncStream<PendingTranscript?>.Continuation
    private let environment: SttEnvironment

    private var engine: AVAudioEngine?
    private var models: AsrModels?
    private var language: SttLanguage
    private var currentDeviceId: AudioDeviceID?

    private var bufferContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var forwardingTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var clamshellCheckTask: Task<Void, Never>?
    private var aneUpgradeTask: Task<Void, Never>?
    private var userStopFinalizationTask: Task<Void, Never>?

    var isCurrentlyCapturing: Bool { captureMode == .capturing }
    var currentStatus: SttStatus { status }
    var currentPermissions: PermissionSnapshot { permissions }
    var currentPendingTranscript: PendingTranscript? { pendingTranscript }

    private var status: SttStatus = .idle(detail: "Waiting to prepare")
    private var permissions: PermissionSnapshot
    private var pendingTranscript: PendingTranscript?
    private var captureMode: CaptureMode = .idle
    private var isRestarting = false
    private var modelBackend: SttModelBackend = .cpu
    private var capturedSamples: [Float] = []
    private var captureProcessingError: Error?

    static func modelsDirectory(for language: SttLanguage) -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("macSTT", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(language.repo.folderName, isDirectory: true)
    }

    init(language: SttLanguage = .english, environment: SttEnvironment = .live) {
        self.monitor = AudioDeviceMonitor()
        self.language = language
        self.environment = environment
        self.permissions = environment.permissionSnapshot()
        self.pendingTranscript = environment.loadPendingTranscript()

        let (statusStream, statusCont) = AsyncStream<SttStatus>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let (permissionStream, permissionCont) = AsyncStream<PermissionSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let (pendingTranscriptStream, pendingTranscriptCont) = AsyncStream<PendingTranscript?>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.statusUpdates = statusStream
        self.permissionUpdates = permissionStream
        self.pendingTranscriptUpdates = pendingTranscriptStream
        self.statusContinuation = statusCont
        self.permissionContinuation = permissionCont
        self.pendingTranscriptContinuation = pendingTranscriptCont
    }

    // MARK: - Status

    private func setStatus(_ newStatus: SttStatus) {
        status = newStatus
        statusContinuation.yield(newStatus)
    }

    private func setPreparingStatus(_ phase: SttPreparationPhase) {
        setStatus(.preparing(phase))
    }

    private func setReadyStatus() {
        setStatus(.ready)
    }

    @discardableResult
    func refreshPermissionState() -> PermissionSnapshot {
        let snapshot = environment.permissionSnapshot()
        guard snapshot != permissions else {
            return permissions
        }

        permissions = snapshot
        permissionContinuation.yield(snapshot)
        return snapshot
    }

    func requestMicrophonePermission() async -> PermissionSnapshot {
        _ = await environment.requestMicrophonePermission()
        return refreshPermissionState()
    }

    func promptInputMonitoringPermission() -> PermissionSnapshot {
        environment.promptInputMonitoringPermission()
        return refreshPermissionState()
    }

    func promptAccessibilityPermission() -> PermissionSnapshot {
        environment.promptAccessibilityPermission()
        return refreshPermissionState()
    }

    func dismissPendingTranscript() {
        setPendingTranscript(nil)
    }

    private func setPendingTranscript(_ pendingTranscript: PendingTranscript?) {
        self.pendingTranscript = pendingTranscript
        environment.savePendingTranscript(pendingTranscript)
        pendingTranscriptContinuation.yield(pendingTranscript)
    }

    // MARK: - Lifecycle

    func prepare() async {
        guard !status.hasLoadedModels else { return }
        guard !status.isPreparing else { return }
        _ = refreshPermissionState()
        feedbackSoundPlayer.prepare()

        do {
            try await monitor.startMonitoring()

            monitorTask = Task { [weak self] in
                guard let self else { return }
                for await deviceId in self.monitor.deviceChanges {
                    await self.handleDeviceChange(deviceId)
                }
            }

            notificationTask = Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(
                    named: .AVAudioEngineConfigurationChange
                ) {
                    guard let self else { return }
                    await self.handleEngineConfigurationChange()
                }
            }

            try await downloadAndLoadWithProgress()
            logger.info("STT prepared")
        } catch {
            setStatus(.error(error.localizedDescription))
            logger.error("Failed to prepare STT: \(error)")
        }
    }

    func beginCapture() async -> CaptureAttemptResult {
        let permissionSnapshot = refreshPermissionState()
        guard permissionSnapshot.allGranted else {
            logger.info(
                "Permissions missing, capture blocked: mic=\(permissionSnapshot.microphone.rawValue) input=\(permissionSnapshot.inputMonitoring.rawValue) ax=\(permissionSnapshot.accessibility.rawValue)"
            )
            feedbackSoundPlayer.play(.captureRejected)
            return .blockedByPermissions
        }

        guard status.canStartCapture, captureMode == .idle else {
            if !status.canStartCapture {
                logger.info("Models not ready (\(status)), trigger ignored")
                feedbackSoundPlayer.play(.captureRejected)
            } else if captureMode == .finalizingUserStop {
                logger.info("Capture trigger ignored — previous transcription is still finalizing")
            }
            return .ignored
        }
        captureMode = .capturing
        resetCapturedAudio()
        switchAwayFromBuiltInIfClamshell()

        do {
            try await startCaptureSession()
            startClamshellCheck()
            feedbackSoundPlayer.play(.captureStarted)
            logger.info("Capture started")
            return .started
        } catch {
            captureMode = .idle
            clamshellCheckTask?.cancel()
            clamshellCheckTask = nil
            let updatedPermissions = refreshPermissionState()
            logger.error("Failed to start capture: \(error)")
            return updatedPermissions.allGranted ? .ignored : .blockedByPermissions
        }
    }

    func endCapture() async {
        await stopCapturing(reason: .userStop)
        logger.info("Capture stop acknowledged")
    }

    func toggleCaptureFromTrigger() async -> CaptureToggleResult {
        switch captureMode {
        case .idle:
            switch await beginCapture() {
            case .started:
                return .started
            case .blockedByPermissions:
                return .blockedByPermissions
            case .ignored:
                return .ignored
            }
        case .capturing:
            await endCapture()
            return .stopped
        case .finalizingUserStop:
            logger.info("Trigger ignored — transcription finalization is still running")
            return .ignored
        }
    }

    func shutdown() async {
        await stopCapturing(reason: .shutdown)
        await userStopFinalizationTask?.value

        aneUpgradeTask?.cancel()
        aneUpgradeTask = nil
        monitorTask?.cancel()
        notificationTask?.cancel()
        clamshellCheckTask?.cancel()
        monitorTask = nil
        notificationTask = nil
        clamshellCheckTask = nil

        models = nil
        await batchAsrRuntime.cleanup()
        await monitor.stopMonitoring()

        statusContinuation.finish()
        permissionContinuation.finish()
        pendingTranscriptContinuation.finish()
        logger.info("STT shut down")
    }

    func switchLanguage(_ newLanguage: SttLanguage) async throws {
        guard newLanguage != language else { return }

        let wasCapturing = captureMode == .capturing
        if wasCapturing {
            await stopCapturing(reason: .languageSwitch)
        }

        aneUpgradeTask?.cancel()
        aneUpgradeTask = nil
        language = newLanguage
        models = nil

        do {
            try await downloadAndLoadWithProgress()
        } catch {
            setStatus(.error(error.localizedDescription))
            throw error
        }

        if wasCapturing {
            _ = await beginCapture()
        }

        logger.info("Switched to \(newLanguage.rawValue) model")
    }

    // MARK: - Model management

    /// Unified download + CPU-only load with single progress percentage.
    /// Download phase = 0-90%, CPU load = 90%→Ready. ANE upgrade runs silently after.
    private func downloadAndLoadWithProgress() async throws {
        let dir = Self.modelsDirectory(for: language)
        let version = language.modelVersion
        setPreparingStatus(.checkingModelCache(language: language))
        let needsDownload = !AsrModels.modelsExist(at: dir, version: version)

        if needsDownload {
            let trackingItems = Self.downloadTrackingItems
            let parentDir = dir.deletingLastPathComponent()

            setPreparingStatus(.downloadingModels(
                language: language,
                completedFiles: 0,
                totalFiles: trackingItems.count
            ))

            let pollerTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { break }
                    let completed = Self.countCompleted(items: trackingItems, in: dir)
                    self.setPreparingStatus(.downloadingModels(
                        language: self.language,
                        completedFiles: completed,
                        totalFiles: trackingItems.count
                    ))
                }
            }
            defer { pollerTask.cancel() }

            try await DownloadUtils.downloadRepo(language.repo, to: parentDir)
        }

        // CPU-only load — fast (~130ms), makes the app usable immediately
        setPreparingStatus(.loadingModels(
            language: language,
            backend: .cpu,
            detail: "Loading Core ML bundles",
            percent: 92
        ))
        try await loadModels(computeUnits: .cpuOnly)
        modelBackend = .cpu
        setReadyStatus()

        // Reload with Neural Engine in background — better inference performance
        aneUpgradeTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.upgradeModelsToNeuralEngine()
        }
    }

    private static let downloadTrackingItems = [
        "Preprocessor.mlmodelc/coremldata.bin",
        "Encoder.mlmodelc/coremldata.bin",
        "Decoder.mlmodelc/coremldata.bin",
        "JointDecision.mlmodelc/coremldata.bin",
        "parakeet_vocab.json",
    ]

    private static func countCompleted(items: [String], in directory: URL) -> Int {
        let fm = FileManager.default
        return items.reduce(0) { count, item in
            let path = directory.appendingPathComponent(item)
            return count + (fm.fileExists(atPath: path.path) ? 1 : 0)
        }
    }

    private func loadModels(computeUnits: MLComputeUnits) async throws {
        let dir = Self.modelsDirectory(for: language)
        let version = language.modelVersion
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        logger.info("Loading ASR models (version: \(version), computeUnits: \(computeUnits))...")
        let loadedModels = try await AsrModels.load(from: dir, configuration: config, version: version)
        try await batchAsrRuntime.loadModels(loadedModels)
        self.models = loadedModels
        logger.info("ASR models loaded")
    }

    private func upgradeModelsToNeuralEngine() async {
        do {
            try await loadModels(computeUnits: .cpuAndNeuralEngine)
            modelBackend = .neuralEngine
            if captureMode != .capturing {
                setReadyStatus()
            }
            logger.info("Upgraded to ANE models")
        } catch {
            if captureMode != .capturing {
                setReadyStatus()
            }
            logger.error("ANE model load failed, continuing with CPU: \(error)")
        }
    }

    // MARK: - Capture session

    private func stopCapturing(reason: CaptureStopReason) async {
        guard captureMode == .capturing else { return }
        clamshellCheckTask?.cancel()
        clamshellCheckTask = nil
        if reason != .userStop {
            captureMode = .idle
        } else {
            captureMode = .finalizingUserStop
        }

        let finalizedBatch = await stopCaptureSession(reason: reason)
        if let finalizedBatch {
            startUserStopFinalization(finalizedBatch)
        } else if reason == .userStop {
            captureMode = .idle
        }
    }

    private func startCaptureSession() async throws {
        guard let models else {
            throw SttError.modelsNotLoaded
        }
        _ = models

        // Buffer bridge: tap -> AsyncStream -> batch capture
        let (bufferStream, bufCont) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.bufferContinuation = bufCont

        forwardingTask = Task(priority: .userInitiated) { [weak self] in
            for await buffer in bufferStream {
                guard let self else { return }
                await self.captureAudioBuffer(buffer)
            }
        }

        try startEngine()

        if let device = AudioDeviceMonitor.getDefaultInputDevice() {
            currentDeviceId = device.id
            logger.info("Capturing on device: \"\(device.name)\"")
        } else {
            logger.info("Capturing on default input device")
        }
    }

    private func stopCaptureSession(reason: CaptureStopReason) async -> FinalizedCaptureBatch? {
        stopEngine()
        logger.info("Engine stopped, finalizing capture...")

        bufferContinuation?.finish()
        bufferContinuation = nil
        let forwardingTask = self.forwardingTask
        self.forwardingTask = nil
        await forwardingTask?.value

        return drainCapturedAudioForFinalization(reason: reason)
    }

    func commitTranscription(_ finalText: String) async {
        guard !finalText.isEmpty else {
            logger.info("No text recognized in this session")
            return
        }

        logger.info("[FINAL] \(finalText)")
        do {
            try environment.typeTextAtCursor(finalText)
        } catch {
            let pendingTranscript = PendingTranscript(
                text: finalText,
                failureReason: Self.pendingTranscriptFailureReason(for: error)
            )
            setPendingTranscript(pendingTranscript)
            _ = refreshPermissionState()
            logger.error("Failed to type transcription: \(error)")
        }
    }

    private static func pendingTranscriptFailureReason(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }

        return error.localizedDescription
    }

    // MARK: - Audio engine

    private func startEngine() throws {
        let newEngine = AVAudioEngine()
        self.engine = newEngine

        let inputNode = newEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        logger.info("Input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")

        inputNode.installTap(onBus: 0, bufferSize: Self.captureTapBufferSize, format: inputFormat) {
            [bufferContinuation] buffer, _ in
            bufferContinuation?.yield(buffer)
        }

        newEngine.prepare()
        try newEngine.start()
    }

    private func stopEngine() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        currentDeviceId = nil
    }

    // MARK: - Device change handling

    private func handleDeviceChange(_ deviceId: AudioDeviceID) async {
        guard status.hasLoadedModels else {
            logger.info("Device change ignored — not ready (id: \(deviceId))")
            return
        }
        guard deviceId != currentDeviceId else {
            logger.info("Device change deduplicated — same device (id: \(deviceId), current: \(currentDeviceId ?? 0))")
            return
        }
        if let device = AudioDeviceMonitor.getDefaultInputDevice() {
            logger.info(
                "Device change: \"\(device.name)\" (id:\(device.id), transport:\(device.transport), alive:\(device.isAlive)) — capturing:\(captureMode == .capturing)"
            )
        }
        if captureMode == .capturing {
            await restartCaptureSession()
        }
    }

    private func handleEngineConfigurationChange() async {
        guard status.hasLoadedModels else { return }
        logger.info("AVAudioEngine configuration change notification")
        if captureMode == .capturing {
            await restartCaptureSession()
        }
    }

    // MARK: - Clamshell fallback

    private func switchAwayFromBuiltInIfClamshell() {
        guard AudioDeviceMonitor.isClamshellClosed(),
              let current = AudioDeviceMonitor.getDefaultInputDevice(),
              current.transport == "BuiltIn",
              let external = AudioDeviceMonitor.bestExternalInputDevice() else { return }
        AudioDeviceMonitor.setDefaultInputDevice(external.id)
        logger.info("Clamshell closed — switched from \"\(current.name)\" to \"\(external.name)\"")
    }

    private func startClamshellCheck() {
        clamshellCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                guard await self.isCurrentlyCapturing else { return }
                await self.switchAwayFromBuiltInIfClamshell()
            }
        }
    }

    private func restartCaptureSession() async {
        guard !isRestarting else {
            logger.info("Restart skipped — already restarting")
            return
        }
        guard captureMode == .capturing else {
            logger.info("Restart skipped — capture is no longer active")
            return
        }
        isRestarting = true
        defer { isRestarting = false }

        logger.info("Restarting capture session...")
        _ = await stopCaptureSession(reason: .internalRestart)
        try? await Task.sleep(for: .milliseconds(100))
        guard captureMode == .capturing else {
            logger.info("Restart aborted — capture was stopped during delay")
            return
        }

        do {
            try await startCaptureSession()
            if let device = AudioDeviceMonitor.getDefaultInputDevice() {
                logger.info("Restarted on device: \"\(device.name)\" (transport:\(device.transport), alive:\(device.isAlive))")
            }
        } catch {
            _ = refreshPermissionState()
            logger.error("Failed to restart capture session: \(error)")
        }
    }

    private func captureAudioBuffer(_ buffer: AVAudioPCMBuffer) async {
        guard captureProcessingError == nil else { return }

        do {
            let samples = try audioConverter.resampleBuffer(buffer)
            guard !samples.isEmpty else { return }
            capturedSamples.append(contentsOf: samples)
        } catch {
            if captureProcessingError == nil {
                captureProcessingError = error
            }
            logger.error("Audio buffer processing failed: \(error)")
        }
    }

    private func drainCapturedAudioForFinalization(reason: CaptureStopReason) -> FinalizedCaptureBatch? {
        if let captureProcessingError {
            logger.error("Captured audio processing failed during \(reason.description): \(captureProcessingError)")
            if reason != .internalRestart {
                resetCapturedAudio()
            }
            return nil
        }

        switch reason {
        case .internalRestart:
            logger.info("Retaining \(capturedSamples.count) captured samples during internal restart")
            return nil
        case .shutdown, .languageSwitch:
            if !capturedSamples.isEmpty {
                logger.info("Discarded \(capturedSamples.count) captured samples during \(reason.description)")
            }
            resetCapturedAudio()
            return nil
        case .userStop:
            break
        }

        let samples = capturedSamples
        guard !samples.isEmpty else {
            logger.info("No audio captured in this session")
            resetCapturedAudio()
            return nil
        }

        resetCapturedAudio()
        return FinalizedCaptureBatch(samples: samples, backend: modelBackend)
    }

    private func startUserStopFinalization(_ finalizedBatch: FinalizedCaptureBatch) {
        let task = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.processUserStopFinalization(finalizedBatch)
            await self.finishUserStopFinalization()
        }
        userStopFinalizationTask = task
    }

    private func processUserStopFinalization(_ finalizedBatch: FinalizedCaptureBatch) async {
        let durationSeconds = Double(finalizedBatch.samples.count) / 16_000.0
        logger.info(
            "Transcribing captured batch: \(finalizedBatch.samples.count) samples (~\(String(format: "%.2f", durationSeconds))s) on \(finalizedBatch.backend.displayName)"
        )

        do {
            let finalText = try await transcribeCapturedSamples(finalizedBatch.samples)
            guard !Task.isCancelled else { return }
            logger.info("ASR batch returned \(finalText.count) chars")
            await commitTranscription(finalText)
        } catch {
            logger.error("Batch transcription failed during user stop: \(error)")
        }
    }

    private func finishUserStopFinalization() {
        if captureMode == .finalizingUserStop {
            captureMode = .idle
        }
        userStopFinalizationTask = nil
    }

    private func transcribeCapturedSamples(_ samples: [Float]) async throws -> String {
        if let transcribeCapturedSamples = environment.transcribeCapturedSamples {
            return try await transcribeCapturedSamples(samples)
        }

        return try await batchAsrRuntime.transcribe(samples)
    }

    private func resetCapturedAudio() {
        capturedSamples.removeAll(keepingCapacity: true)
        captureProcessingError = nil
    }

    #if DEBUG
    func appendCapturedSamplesForTesting(_ samples: [Float]) {
        capturedSamples.append(contentsOf: samples)
    }

    func finalizeCapturedAudioForTesting(reason: CaptureStopReason) async {
        guard let finalizedBatch = drainCapturedAudioForFinalization(reason: reason) else { return }
        await processUserStopFinalization(finalizedBatch)
    }

    var capturedSamplesCountForTesting: Int {
        capturedSamples.count
    }
    #endif
}

enum SttError: Error {
    case modelsNotLoaded
}
