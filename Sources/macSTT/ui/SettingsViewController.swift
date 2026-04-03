import AppKit
import Logging

@MainActor
final class SettingsViewController: NSViewController {
    var onConfigChanged: ((SttConfig) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    private let sttActor: SttActor
    private let triggerRecorder: TriggerRecorderView
    private var statusTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var pendingTranscriptTask: Task<Void, Never>?
    private let logger = Logger(label: "com.wixfi.stt.settings")
    private var config: SttConfig

    private let englishRadio = NSButton(
        radioButtonWithTitle: "English",
        target: nil, action: nil
    )
    private let multilingualRadio = NSButton(
        radioButtonWithTitle: "Multilingual",
        target: nil, action: nil
    )
    private let statusLabel = NSTextField(wrappingLabelWithString: "Status: Initializing")
    private let statusProgressIndicator = NSProgressIndicator()
    private let messageLabel = NSTextField(labelWithString: "")
    private let microphoneStateLabel = NSTextField(labelWithString: "Checking…")
    private let inputMonitoringStateLabel = NSTextField(labelWithString: "Checking…")
    private let accessibilityStateLabel = NSTextField(labelWithString: "Checking…")
    private let microphoneActionButton = NSButton(title: "", target: nil, action: nil)
    private let inputMonitoringActionButton = NSButton(title: "", target: nil, action: nil)
    private let accessibilityActionButton = NSButton(title: "", target: nil, action: nil)
    private let recoveryContainer = NSStackView()
    private let recoveryReasonLabel = NSTextField(wrappingLabelWithString: "")
    private let recoveryTextView = NSTextView()
    private let recoveryScrollView = NSScrollView()

    init(sttActor: SttActor, initialConfig: SttConfig = SttConfig.load()) {
        self.sttActor = sttActor
        self.config = initialConfig
        self.triggerRecorder = TriggerRecorderView(initialTriggers: initialConfig.triggers)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        englishRadio.state = config.language == .english ? .on : .off
        englishRadio.target = self
        englishRadio.action = #selector(languageChanged)

        multilingualRadio.state = config.language == .multilingual ? .on : .off
        multilingualRadio.target = self
        multilingualRadio.action = #selector(languageChanged)

        let languageLabel = NSTextField(labelWithString: "Language:")
        languageLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let triggerLabel = NSTextField(labelWithString: "Trigger:")
        triggerLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        triggerRecorder.onTriggerChanged = { [weak self] in
            self?.handleTriggerChanged()
        }
        triggerRecorder.onRecordingChanged = { [weak self] recording in
            self?.onRecordingChanged?(recording)
        }

        let triggerRow = NSStackView(views: [triggerLabel, triggerRecorder])
        triggerRow.orientation = .horizontal
        triggerRow.spacing = 8

        let permissionsLabel = NSTextField(labelWithString: "Permissions:")
        permissionsLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        microphoneActionButton.target = self
        microphoneActionButton.action = #selector(microphonePermissionAction)
        inputMonitoringActionButton.target = self
        inputMonitoringActionButton.action = #selector(inputMonitoringPermissionAction)
        accessibilityActionButton.target = self
        accessibilityActionButton.action = #selector(accessibilityPermissionAction)

        let permissionsSeparator = NSBox()
        permissionsSeparator.boxType = .separator

        let modelSeparator = NSBox()
        modelSeparator.boxType = .separator

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .labelColor
        statusLabel.maximumNumberOfLines = 0
        configureMetadataLabel(microphoneStateLabel)
        configureMetadataLabel(inputMonitoringStateLabel)
        configureMetadataLabel(accessibilityStateLabel)

        statusProgressIndicator.isIndeterminate = false
        statusProgressIndicator.minValue = 0
        statusProgressIndicator.maxValue = 100
        statusProgressIndicator.controlSize = .small
        statusProgressIndicator.style = .bar
        statusProgressIndicator.isDisplayedWhenStopped = false
        statusProgressIndicator.translatesAutoresizingMaskIntoConstraints = false
        statusProgressIndicator.widthAnchor.constraint(equalToConstant: 220).isActive = true
        statusProgressIndicator.isHidden = true

        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .systemRed
        messageLabel.isHidden = true
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0

        recoveryReasonLabel.font = .systemFont(ofSize: 11)
        recoveryReasonLabel.textColor = .secondaryLabelColor
        recoveryReasonLabel.maximumNumberOfLines = 0

        recoveryTextView.isEditable = false
        recoveryTextView.isSelectable = true
        recoveryTextView.isRichText = false
        recoveryTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        recoveryTextView.textContainerInset = NSSize(width: 8, height: 8)
        recoveryTextView.string = ""

        recoveryScrollView.borderType = .bezelBorder
        recoveryScrollView.hasVerticalScroller = true
        recoveryScrollView.drawsBackground = true
        recoveryScrollView.documentView = recoveryTextView
        recoveryScrollView.translatesAutoresizingMaskIntoConstraints = false
        recoveryScrollView.heightAnchor.constraint(equalToConstant: 120).isActive = true

        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyPendingTranscript))
        let dismissButton = NSButton(title: "Dismiss", target: self, action: #selector(dismissPendingTranscript))
        let recoveryButtonRow = NSStackView(views: [copyButton, dismissButton])
        recoveryButtonRow.orientation = .horizontal
        recoveryButtonRow.spacing = 8

        recoveryContainer.orientation = .vertical
        recoveryContainer.alignment = .leading
        recoveryContainer.spacing = 8
        recoveryContainer.addArrangedSubview(makeSectionLabel("Transcript Recovery"))
        recoveryContainer.addArrangedSubview(recoveryReasonLabel)
        recoveryContainer.addArrangedSubview(recoveryScrollView)
        recoveryContainer.addArrangedSubview(recoveryButtonRow)
        recoveryContainer.isHidden = true

        stack.addArrangedSubview(triggerRow)
        stack.addArrangedSubview(languageLabel)
        stack.addArrangedSubview(englishRadio)
        stack.addArrangedSubview(multilingualRadio)
        stack.addArrangedSubview(permissionsSeparator)
        stack.addArrangedSubview(permissionsLabel)
        stack.addArrangedSubview(makePermissionRow(
            title: "Microphone",
            stateLabel: microphoneStateLabel,
            actionButton: microphoneActionButton
        ))
        stack.addArrangedSubview(makePermissionRow(
            title: "Input Monitoring",
            stateLabel: inputMonitoringStateLabel,
            actionButton: inputMonitoringActionButton
        ))
        stack.addArrangedSubview(makePermissionRow(
            title: "Accessibility",
            stateLabel: accessibilityStateLabel,
            actionButton: accessibilityActionButton
        ))
        stack.addArrangedSubview(recoveryContainer)
        stack.addArrangedSubview(modelSeparator)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(statusProgressIndicator)
        stack.addArrangedSubview(messageLabel)

        self.view = stack

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(syncWindowState),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        startStatusTask()
        startPermissionTask()
        startPendingTranscriptTask()
    }

    deinit {
        statusTask?.cancel()
        permissionTask?.cancel()
        pendingTranscriptTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func syncWindowState() {
        Task {
            await sttActor.refreshPermissionState()
        }
    }

    @objc private func languageChanged(_ sender: NSButton) {
        let previous = config
        config.language = sender === englishRadio ? .english : .multilingual
        englishRadio.state = config.language == .english ? .on : .off
        multilingualRadio.state = config.language == .multilingual ? .on : .off
        persistConfig(orRollbackTo: previous) { [weak self] in
            guard let self else { return }
            self.englishRadio.state = previous.language == .english ? .on : .off
            self.multilingualRadio.state = previous.language == .multilingual ? .on : .off
        }
    }

    @objc private func microphonePermissionAction() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let permissions = await sttActor.currentPermissions
            switch permissions.microphone {
            case .granted:
                break
            case .notDetermined:
                _ = await sttActor.requestMicrophonePermission()
            case .denied:
                Self.openPrivacySettings(anchor: "Privacy_Microphone")
            }
        }
    }

    @objc private func accessibilityPermissionAction() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let permissions = await sttActor.currentPermissions
            switch permissions.accessibility {
            case .granted:
                break
            case .notDetermined:
                _ = await sttActor.promptAccessibilityPermission()
            case .denied:
                Self.openPrivacySettings(anchor: "Privacy_Accessibility")
            }
        }
    }

    @objc private func inputMonitoringPermissionAction() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let permissions = await sttActor.currentPermissions
            switch permissions.inputMonitoring {
            case .granted:
                break
            case .notDetermined:
                _ = await sttActor.promptInputMonitoringPermission()
            case .denied:
                Self.openPrivacySettings(anchor: "Privacy_ListenEvent")
            }
        }
    }

    @objc private func copyPendingTranscript() {
        guard !recoveryTextView.string.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recoveryTextView.string, forType: .string)
    }

    @objc private func dismissPendingTranscript() {
        Task {
            await sttActor.dismissPendingTranscript()
        }
    }

    // MARK: - Config Persistence

    private func handleTriggerChanged() {
        let previous = config
        config.triggers = triggerRecorder.triggers
        persistConfig(orRollbackTo: previous) { [weak self] in
            self?.triggerRecorder.setTriggers(previous.triggers)
        }
    }

    private func persistConfig(orRollbackTo previous: SttConfig, rollback: () -> Void) {
        do {
            try config.save()
            clearMessage()
            onConfigChanged?(config)
        } catch {
            config = previous
            rollback()
            logger.error("Failed to save settings: \(error)")
            showMessage(error.localizedDescription)
        }
    }

    private func showMessage(_ message: String) {
        messageLabel.stringValue = message
        messageLabel.isHidden = false
    }

    private func clearMessage() {
        messageLabel.stringValue = ""
        messageLabel.isHidden = true
    }

    // MARK: - State Tasks

    private func startStatusTask() {
        statusTask?.cancel()
        statusTask = Task { @MainActor [weak self, sttActor] in
            let current = await sttActor.currentStatus
            self?.applyStatus(current)

            for await status in sttActor.statusUpdates {
                guard !Task.isCancelled else { break }
                self?.applyStatus(status)
            }
        }
    }

    private func startPermissionTask() {
        permissionTask?.cancel()
        permissionTask = Task { @MainActor [weak self, sttActor] in
            let current = await sttActor.currentPermissions
            self?.applyPermissions(current)

            for await permissions in sttActor.permissionUpdates {
                guard !Task.isCancelled else { break }
                self?.applyPermissions(permissions)
            }
        }
    }

    private func startPendingTranscriptTask() {
        pendingTranscriptTask?.cancel()
        pendingTranscriptTask = Task { @MainActor [weak self, sttActor] in
            let current = await sttActor.currentPendingTranscript
            self?.applyPendingTranscript(current)

            for await pendingTranscript in sttActor.pendingTranscriptUpdates {
                guard !Task.isCancelled else { break }
                self?.applyPendingTranscript(pendingTranscript)
            }
        }
    }

    // MARK: - State Rendering

    private func applyStatus(_ status: SttStatus) {
        let presentation = status.presentation
        if let detail = presentation.detail, !detail.isEmpty {
            statusLabel.stringValue = "Status: \(presentation.title) — \(detail)"
        } else {
            statusLabel.stringValue = "Status: \(presentation.title)"
        }
        statusLabel.textColor = presentation.isError ? .systemRed : .labelColor

        if presentation.showsProgress {
            statusProgressIndicator.isHidden = false
            statusProgressIndicator.isIndeterminate = presentation.isProgressIndeterminate
            if presentation.isProgressIndeterminate {
                statusProgressIndicator.startAnimation(nil)
            } else {
                statusProgressIndicator.stopAnimation(nil)
                statusProgressIndicator.doubleValue = Double(presentation.progressPercent ?? 0)
            }
        } else {
            statusProgressIndicator.stopAnimation(nil)
            statusProgressIndicator.doubleValue = 0
            statusProgressIndicator.isHidden = true
        }
    }

    private func applyPermissions(_ permissions: PermissionSnapshot) {
        microphoneStateLabel.stringValue = permissions.microphone.displayName
        inputMonitoringStateLabel.stringValue = permissions.inputMonitoring.displayName
        accessibilityStateLabel.stringValue = permissions.accessibility.displayName

        updatePermissionButton(
            microphoneActionButton,
            state: permissions.microphone,
            requestTitle: "Request",
            settingsTitle: "Open Settings"
        )
        updatePermissionButton(
            inputMonitoringActionButton,
            state: permissions.inputMonitoring,
            requestTitle: "Request",
            settingsTitle: "Open Settings"
        )
        updatePermissionButton(
            accessibilityActionButton,
            state: permissions.accessibility,
            requestTitle: "Request",
            settingsTitle: "Open Settings"
        )
    }

    private func applyPendingTranscript(_ pendingTranscript: PendingTranscript?) {
        guard let pendingTranscript else {
            recoveryContainer.isHidden = true
            recoveryReasonLabel.stringValue = ""
            recoveryTextView.string = ""
            return
        }

        recoveryReasonLabel.stringValue = pendingTranscript.failureReason
        recoveryTextView.string = pendingTranscript.text
        recoveryContainer.isHidden = false
    }

    private func updatePermissionButton(
        _ button: NSButton,
        state: PermissionState,
        requestTitle: String,
        settingsTitle: String
    ) {
        switch state {
        case .granted:
            button.isHidden = true
        case .notDetermined:
            button.title = requestTitle
            button.isHidden = false
        case .denied:
            button.title = settingsTitle
            button.isHidden = false
        }
    }

    // MARK: - View Helpers

    private func configureMetadataLabel(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
    }

    private func makeSectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func makePermissionRow(
        title: String,
        stateLabel: NSTextField,
        actionButton: NSButton
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        actionButton.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [titleLabel, spacer, stateLabel, actionButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        return row
    }

    private static func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
