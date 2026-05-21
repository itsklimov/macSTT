import AppKit
import Logging

@MainActor
final class SettingsViewController: NSViewController {
    private static let contentWidth: CGFloat = 400
    private static let rootInset: CGFloat = 16
    private static let groupWidth: CGFloat = contentWidth - (rootInset * 2)
    private static let rowHorizontalInset: CGFloat = 12
    private static let headerIconWidth: CGFloat = 18
    private static let labelColumnWidth: CGFloat = 108
    private static let valueColumnWidth: CGFloat = 196
    private static let progressWidth: CGFloat = 196
    private static let activePermissionRefreshInterval: Duration = .milliseconds(500)
    private static let idlePermissionRefreshInterval: Duration = .seconds(2)

    var onConfigChanged: ((SttConfig) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    private let sttActor: SttActor
    private let triggerRecorder: TriggerRecorderView
    private var statusTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var permissionRefreshTask: Task<Void, Never>?
    private var pendingTranscriptTask: Task<Void, Never>?
    private let logger = Logger(label: "com.wixfi.stt.settings")
    private var config: SttConfig
    private var currentStatus = SttStatus.idle(detail: "Waiting to prepare")
    private var currentPermissions = PermissionSnapshot(
        microphone: .notDetermined,
        accessibility: .notDetermined
    )

    private let languageControl = NSSegmentedControl(
        labels: ["English", "Multilingual"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let statusLabel = NSTextField(labelWithString: "Initializing")
    private let statusDetailLabel = NSTextField(wrappingLabelWithString: "")
    private let statusValueStack = NSStackView()
    private let statusProgressIndicator = NSProgressIndicator()
    private let messageLabel = NSTextField(labelWithString: "")
    private let microphoneStateLabel = NSTextField(labelWithString: "Checking…")
    private let accessibilityStateLabel = NSTextField(labelWithString: "Checking…")
    private let microphoneActionButton = NSButton(title: "", target: nil, action: nil)
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
        stack.alignment = .width
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(
            top: Self.rootInset,
            left: Self.rootInset,
            bottom: Self.rootInset,
            right: Self.rootInset
        )
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true

        languageControl.selectedSegment = config.language == .english ? 0 : 1
        languageControl.target = self
        languageControl.action = #selector(languageChanged)
        languageControl.segmentStyle = .rounded
        languageControl.controlSize = .small
        languageControl.setWidth(76, forSegment: 0)
        languageControl.setWidth(108, forSegment: 1)

        triggerRecorder.onTriggerChanged = { [weak self] in
            self?.handleTriggerChanged()
        }
        triggerRecorder.onRecordingChanged = { [weak self] recording in
            self?.onRecordingChanged?(recording)
        }

        microphoneActionButton.target = self
        microphoneActionButton.action = #selector(microphonePermissionAction)
        accessibilityActionButton.target = self
        accessibilityActionButton.action = #selector(accessibilityPermissionAction)

        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = .labelColor
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingTail

        statusDetailLabel.font = .systemFont(ofSize: 11)
        statusDetailLabel.textColor = .secondaryLabelColor
        statusDetailLabel.alignment = .center
        statusDetailLabel.maximumNumberOfLines = 0
        statusDetailLabel.translatesAutoresizingMaskIntoConstraints = false
        statusDetailLabel.widthAnchor.constraint(
            lessThanOrEqualToConstant: Self.valueColumnWidth
        ).isActive = true
        statusDetailLabel.isHidden = true

        configurePermissionValueLabel(microphoneStateLabel)
        configurePermissionValueLabel(accessibilityStateLabel)

        statusProgressIndicator.isIndeterminate = false
        statusProgressIndicator.minValue = 0
        statusProgressIndicator.maxValue = 100
        statusProgressIndicator.controlSize = .small
        statusProgressIndicator.style = .bar
        statusProgressIndicator.isDisplayedWhenStopped = false
        statusProgressIndicator.translatesAutoresizingMaskIntoConstraints = false
        statusProgressIndicator.widthAnchor.constraint(equalToConstant: Self.progressWidth).isActive = true
        statusProgressIndicator.isHidden = true

        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .systemRed
        messageLabel.alignment = .center
        messageLabel.isHidden = true
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.widthAnchor.constraint(
            lessThanOrEqualToConstant: Self.valueColumnWidth
        ).isActive = true

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

        configureRecoveryContainer(buttonRow: recoveryButtonRow)
        recoveryContainer.isHidden = true

        stack.addArrangedSubview(makeHeader())
        stack.addArrangedSubview(makeSettingsGroup(rows: [
            makeSettingsRow(title: "Trigger", trailingView: triggerRecorder),
            makeSettingsRow(title: "Language", trailingView: languageControl),
        ]))
        stack.addArrangedSubview(makeSettingsGroup(rows: [
            makePermissionRow(
                title: "Microphone",
                stateLabel: microphoneStateLabel,
                actionButton: microphoneActionButton
            ),
            makePermissionRow(
                title: "Accessibility",
                stateLabel: accessibilityStateLabel,
                actionButton: accessibilityActionButton
            ),
        ]))
        stack.addArrangedSubview(recoveryContainer)
        stack.addArrangedSubview(makeSettingsGroup(rows: [makeStatusGroup()]))

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
        startPermissionRefreshTask()
        startPendingTranscriptTask()
    }

    deinit {
        statusTask?.cancel()
        permissionTask?.cancel()
        permissionRefreshTask?.cancel()
        pendingTranscriptTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func syncWindowState() {
        Task {
            await sttActor.refreshPermissionState()
        }
    }

    @objc private func languageChanged(_ sender: NSSegmentedControl) {
        let previous = config
        config.language = sender.selectedSegment == 0 ? .english : .multilingual
        persistConfig(orRollbackTo: previous) { [weak self] in
            guard let self else { return }
            self.languageControl.selectedSegment = previous.language == .english ? 0 : 1
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
        resizeWindowToFitContent()
    }

    private func clearMessage() {
        messageLabel.stringValue = ""
        messageLabel.isHidden = true
        resizeWindowToFitContent()
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

    private func startPermissionRefreshTask() {
        permissionRefreshTask?.cancel()
        permissionRefreshTask = Task { @MainActor [weak self, sttActor] in
            while !Task.isCancelled {
                let permissions = await sttActor.refreshPermissionState()
                self?.applyPermissions(permissions)

                let interval = permissions.requiresAttention
                    ? Self.activePermissionRefreshInterval
                    : Self.idlePermissionRefreshInterval
                try? await Task.sleep(for: interval)
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
        currentStatus = status
        renderSystemStatus()
    }

    private func applyPermissions(_ permissions: PermissionSnapshot) {
        currentPermissions = permissions
        updatePermissionRow(
            state: permissions.microphone,
            stateLabel: microphoneStateLabel,
            actionButton: microphoneActionButton
        )
        updatePermissionRow(
            state: permissions.accessibility,
            stateLabel: accessibilityStateLabel,
            actionButton: accessibilityActionButton
        )
        renderSystemStatus()
    }

    private func renderSystemStatus() {
        statusProgressIndicator.stopAnimation(nil)
        statusProgressIndicator.doubleValue = 0
        statusProgressIndicator.isHidden = true
        statusLabel.isHidden = false
        statusDetailLabel.stringValue = ""
        statusDetailLabel.isHidden = true

        let presentation = currentStatus.presentation
        if presentation.showsProgress {
            statusLabel.isHidden = true
            statusDetailLabel.stringValue = presentation.detail ?? presentation.title
            statusDetailLabel.textColor = .secondaryLabelColor
            statusDetailLabel.isHidden = false
            statusProgressIndicator.isHidden = false
            statusProgressIndicator.isIndeterminate = presentation.isProgressIndeterminate
            if presentation.isProgressIndeterminate {
                statusProgressIndicator.startAnimation(nil)
            } else {
                statusProgressIndicator.doubleValue = Double(presentation.progressPercent ?? 0)
            }
            resizeWindowToFitContent()
            return
        }

        if presentation.isError {
            statusLabel.stringValue = presentation.title
            statusLabel.textColor = .systemRed
            if let detail = presentation.detail, !detail.isEmpty {
                statusDetailLabel.stringValue = detail
                statusDetailLabel.textColor = .systemRed
                statusDetailLabel.isHidden = false
            }
            resizeWindowToFitContent()
            return
        }

        guard currentStatus.canStartCapture else {
            statusLabel.stringValue = "Not Ready"
            statusLabel.textColor = .secondaryLabelColor
            if let detail = presentation.detail, !detail.isEmpty {
                statusDetailLabel.stringValue = detail
                statusDetailLabel.textColor = .secondaryLabelColor
                statusDetailLabel.isHidden = false
            }
            resizeWindowToFitContent()
            return
        }

        guard currentPermissions.allGranted else {
            statusLabel.stringValue = "Needs Permissions"
            statusLabel.textColor = .systemOrange
            statusDetailLabel.stringValue = missingPermissionSummary(currentPermissions)
            statusDetailLabel.textColor = .secondaryLabelColor
            statusDetailLabel.isHidden = false
            resizeWindowToFitContent()
            return
        }

        statusLabel.stringValue = "Ready"
        statusLabel.textColor = .systemGreen
        resizeWindowToFitContent()
    }

    private func missingPermissionSummary(_ permissions: PermissionSnapshot) -> String {
        var missing = [String]()
        if permissions.microphone != .granted {
            missing.append("Microphone")
        }
        if permissions.accessibility != .granted {
            missing.append("Accessibility")
        }
        return missing.joined(separator: ", ")
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

    private func updatePermissionRow(
        state: PermissionState,
        stateLabel: NSTextField,
        actionButton: NSButton
    ) {
        stateLabel.stringValue = state.displayName
        stateLabel.textColor = permissionStateTextColor(state)

        switch state {
        case .granted:
            actionButton.title = ""
            actionButton.isEnabled = false
            actionButton.isHidden = true
            actionButton.isTransparent = true
        case .notDetermined:
            actionButton.title = "Allow"
            actionButton.isEnabled = true
            actionButton.isHidden = false
            actionButton.isTransparent = false
        case .denied:
            actionButton.title = "Settings…"
            actionButton.isEnabled = true
            actionButton.isHidden = false
            actionButton.isTransparent = false
        }
    }

    // MARK: - View Helpers

    private func configurePermissionValueLabel(_ label: NSTextField) {
        label.font = .labelFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 94).isActive = true
        label.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func makeHeader() -> NSView {
        let titleLabel = NSTextField(labelWithString: "Settings")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .labelColor

        let header = NSStackView(views: [
            makeHeaderIconView(),
            titleLabel,
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalToConstant: Self.groupWidth).isActive = true
        return header
    }

    private func makeSettingsGroup(rows: [NSView]) -> NSBox {
        let group = NSBox()
        group.boxType = .custom
        group.borderWidth = 0
        group.cornerRadius = 8
        group.fillColor = .controlBackgroundColor
        group.contentViewMargins = NSSize(width: 0, height: 0)
        group.translatesAutoresizingMaskIntoConstraints = false
        group.widthAnchor.constraint(equalToConstant: Self.groupWidth).isActive = true

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false

        for (index, row) in rows.enumerated() {
            content.addArrangedSubview(row)
            if index < rows.count - 1 {
                content.addArrangedSubview(makeSeparator())
            }
        }

        group.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: group.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: group.trailingAnchor),
            content.topAnchor.constraint(equalTo: group.topAnchor),
            content.bottomAnchor.constraint(equalTo: group.bottomAnchor),
        ])

        return group
    }

    private func makeSettingsRow(
        title: String,
        trailingView: NSView
    ) -> NSStackView {
        let titleLabel = makeRowTitleLabel(title)
        let spacer = flexibleSpacer()

        trailingView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        trailingView.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let row = NSStackView(views: [
            titleLabel,
            spacer,
            makeValueColumn(trailingView),
        ])
        configureRow(row)
        return row
    }

    private func makePermissionRow(
        title: String,
        stateLabel: NSTextField,
        actionButton: NSButton
    ) -> NSStackView {
        configurePermissionButton(actionButton)

        let row = NSStackView(views: [
            makeRowTitleLabel(title),
            flexibleSpacer(),
            makeValueColumn(makePermissionValueView(stateLabel: stateLabel, actionButton: actionButton)),
        ])
        configureRow(row)
        return row
    }

    private func makeStatusGroup() -> NSView {
        statusValueStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        statusValueStack.addArrangedSubview(statusLabel)
        statusValueStack.addArrangedSubview(statusProgressIndicator)
        statusValueStack.addArrangedSubview(statusDetailLabel)
        statusValueStack.addArrangedSubview(messageLabel)
        statusValueStack.orientation = .vertical
        statusValueStack.alignment = .trailing
        statusValueStack.spacing = 4
        statusValueStack.translatesAutoresizingMaskIntoConstraints = false
        statusValueStack.widthAnchor.constraint(equalToConstant: Self.valueColumnWidth).isActive = true
        renderSystemStatus()

        return makeSettingsRow(
            title: "Model",
            trailingView: statusValueStack
        )
    }

    private func configureRecoveryContainer(buttonRow: NSStackView) {
        let recoveryContent = NSStackView(views: [
            recoveryReasonLabel,
            recoveryScrollView,
            buttonRow,
        ])
        recoveryContent.orientation = .vertical
        recoveryContent.alignment = .width
        recoveryContent.spacing = 8
        recoveryContent.edgeInsets = NSEdgeInsets(
            top: 12,
            left: Self.rowHorizontalInset,
            bottom: 12,
            right: Self.rowHorizontalInset
        )

        recoveryContainer.orientation = .vertical
        recoveryContainer.alignment = .width
        recoveryContainer.spacing = 0
        recoveryContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        recoveryContainer.addArrangedSubview(makeSettingsGroup(rows: [recoveryContent]))
    }

    private func configureRow(_ row: NSStackView) {
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(
            top: 8,
            left: Self.rowHorizontalInset,
            bottom: 8,
            right: Self.rowHorizontalInset
        )
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
    }

    private func makeRowTitleLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .labelFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth).isActive = true
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    private func makePermissionValueView(stateLabel: NSTextField, actionButton: NSButton) -> NSStackView {
        let valueView = NSStackView(views: [stateLabel, actionButton])
        valueView.orientation = .horizontal
        valueView.alignment = .centerY
        valueView.spacing = 8
        return valueView
    }

    private func makeValueColumn(_ contentView: NSView) -> NSView {
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false
        column.widthAnchor.constraint(equalToConstant: Self.valueColumnWidth).isActive = true

        contentView.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            contentView.centerYAnchor.constraint(equalTo: column.centerYAnchor),
            contentView.leadingAnchor.constraint(greaterThanOrEqualTo: column.leadingAnchor),
        ])

        return column
    }

    private func makeHeaderIconView() -> NSImageView {
        let configuration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        let imageView = NSImageView(image: image ?? NSImage(size: NSSize(width: Self.headerIconWidth, height: Self.headerIconWidth)))
        imageView.contentTintColor = .controlAccentColor
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.widthAnchor.constraint(equalToConstant: Self.headerIconWidth).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: Self.headerIconWidth).isActive = true
        return imageView
    }

    private func makeSeparator() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: Self.rowHorizontalInset
            ),
            separator.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -Self.rowHorizontalInset
            ),
            separator.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        return container
    }

    private func flexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private func configurePermissionButton(_ actionButton: NSButton) {
        actionButton.title = "Allow"
        actionButton.font = .labelFont(ofSize: 12)
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.widthAnchor.constraint(equalToConstant: 82).isActive = true
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func permissionStateTextColor(_ state: PermissionState) -> NSColor {
        switch state {
        case .granted:
            .labelColor
        case .notDetermined:
            .secondaryLabelColor
        case .denied:
            .systemRed
        }
    }

    private func resizeWindowToFitContent() {
        guard isViewLoaded, let window = view.window else { return }

        view.needsLayout = true
        view.layoutSubtreeIfNeeded()

        let fittingHeight = ceil(view.fittingSize.height)
        guard fittingHeight > 0 else { return }

        let currentContentHeight = window.contentView?.bounds.height ?? 0
        guard abs(currentContentHeight - fittingHeight) > 1 else { return }

        let currentFrame = window.frame
        var targetFrame = window.frameRect(
            forContentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.contentWidth,
                height: fittingHeight
            )
        )
        targetFrame.origin.x = currentFrame.origin.x
        targetFrame.origin.y = currentFrame.maxY - targetFrame.height
        window.setFrame(targetFrame, display: true)
    }

    private static func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
