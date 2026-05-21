import AppKit
import Logging
import ServiceManagement

private enum StatusMenuSummary {
    static func title(
        status: SttStatus,
        permissions: PermissionSnapshot,
        pendingTranscript: PendingTranscript?
    ) -> String {
        if permissions.requiresAttention {
            return "Status: Permissions Required"
        }

        if pendingTranscript != nil {
            return "Status: Transcript Recovery Required"
        }

        return "Status: \(status.presentation.summaryText)"
    }
}

@MainActor
private enum MenuRowMetrics {
    static let width: CGFloat = 250
    static let height: CGFloat = 28
    static let iconSize: CGFloat = 16
    static let horizontalInset: CGFloat = 16
    static let verticalInset: CGFloat = 5
    static let spacing: CGFloat = 8
}

enum LaunchAtLoginRegistrationPolicy {
    static func shouldRegisterAfterPermissionRelaunch(
        isAppBundle: Bool,
        status: SMAppService.Status,
        didCompletePermissionRelaunch: Bool
    ) -> Bool {
        guard isAppBundle, didCompletePermissionRelaunch else { return false }

        switch status {
        case .notRegistered:
            return true
        default:
            return false
        }
    }
}

@MainActor
private class MenuRowView: NSView {
    let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let spacerView = NSView()
    let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 6

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: MenuRowMetrics.iconSize).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: MenuRowMetrics.iconSize).isActive = true

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail

        spacerView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = MenuRowMetrics.spacing
        stack.edgeInsets = NSEdgeInsets(
            top: MenuRowMetrics.verticalInset,
            left: MenuRowMetrics.horizontalInset,
            bottom: MenuRowMetrics.verticalInset,
            right: MenuRowMetrics.horizontalInset
        )
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: MenuRowMetrics.width),
            heightAnchor.constraint(equalToConstant: MenuRowMetrics.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(icon: NSImage?, title: String, trailingView: NSView? = nil) {
        iconView.image = icon
        titleLabel.stringValue = title

        stack.setViews([], in: .leading)
        var views: [NSView] = [iconView, titleLabel, spacerView]
        if let trailingView {
            views.append(trailingView)
        }
        stack.setViews(views, in: .leading)
    }

    func applyEnabled(_ isEnabled: Bool, toolTip: String?) {
        self.toolTip = toolTip
        titleLabel.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        iconView.contentTintColor = isEnabled ? .secondaryLabelColor : .disabledControlTextColor
        alphaValue = isEnabled ? 1 : 0.7
    }

    func setHighlighted(_ highlighted: Bool) {
        layer?.backgroundColor = highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
    }
}

@MainActor
private final class MenuActionItemView: MenuRowView {
    var onActivate: (() -> Void)?
    private var isRowEnabled = true

    override func mouseDown(with event: NSEvent) {
        guard isRowEnabled else { return }
        setHighlighted(true)
    }

    override func mouseUp(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let shouldActivate = isRowEnabled && bounds.contains(localPoint)
        setHighlighted(false)
        if shouldActivate {
            onActivate?()
        }
    }

    override func mouseExited(with event: NSEvent) {
        setHighlighted(false)
    }

    func update(isEnabled: Bool, toolTip: String?) {
        isRowEnabled = isEnabled
        applyEnabled(isEnabled, toolTip: toolTip)
    }
}

@MainActor
private final class LaunchAtLoginMenuItemView: MenuRowView {
    private let toggleSwitch = NSSwitch()
    var onToggle: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        toggleSwitch.target = self
        toggleSwitch.action = #selector(toggleChanged)
        toggleSwitch.setContentHuggingPriority(.required, for: .horizontal)

        configure(
            icon: StatusItemController.makeMenuIcon(systemName: "power"),
            title: "Start at Login",
            trailingView: toggleSwitch
        )
    }

    func update(isOn: Bool, isEnabled: Bool, toolTip: String?) {
        toggleSwitch.state = isOn ? .on : .off
        toggleSwitch.isEnabled = isEnabled
        toggleSwitch.toolTip = toolTip
        applyEnabled(isEnabled, toolTip: toolTip)
    }

    @objc private func toggleChanged() {
        onToggle?(toggleSwitch.state == .on)
    }
}

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let sttActor: SttActor
    private let openSettings: @MainActor () -> Void
    private let logger = Logger(label: "com.wixfi.stt.app")
    private let isAppBundle = Bundle.main.bundlePath.hasSuffix(".app")

    private var statusItem: NSStatusItem!
    private var statusSummaryItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem?
    private var launchAtLoginView: LaunchAtLoginMenuItemView?
    private var statusTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var pendingTranscriptTask: Task<Void, Never>?
    private var currentStatus: SttStatus = .idle(detail: "Waiting to prepare")
    private var currentPermissions = PermissionSnapshot(
        microphone: .notDetermined,
        accessibility: .notDetermined
    )
    private var currentPendingTranscript: PendingTranscript?

    init(
        sttActor: SttActor,
        openSettings: @escaping @MainActor () -> Void
    ) {
        self.sttActor = sttActor
        self.openSettings = openSettings
        super.init()
        setupStatusItem()
        startStateObservers()
    }

    deinit {
        statusTask?.cancel()
        permissionTask?.cancel()
        pendingTranscriptTask?.cancel()
    }

    func shutdown() {
        statusTask?.cancel()
        permissionTask?.cancel()
        pendingTranscriptTask?.cancel()
    }

    func refreshLaunchAtLoginState() {
        updateLaunchAtLoginMenuItem()
    }

    func enableLaunchAtLoginAfterPermissionRelaunchIfNeeded() {
        guard LaunchAtLoginRegistrationPolicy.shouldRegisterAfterPermissionRelaunch(
            isAppBundle: isAppBundle,
            status: SMAppService.mainApp.status,
            didCompletePermissionRelaunch: true
        ) else {
            updateLaunchAtLoginMenuItem()
            return
        }

        setLaunchAtLoginEnabled(true, shouldOpenApprovalSettings: false)
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateLaunchAtLoginMenuItem()
    }

    fileprivate static func makeMenuIcon(systemName: String) -> NSImage? {
        let baseImage = NSImage(
            systemSymbolName: systemName,
            accessibilityDescription: nil
        )
        let image = baseImage?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        )
        image?.isTemplate = true
        return image
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = makeStatusIcon()

        let menu = NSMenu()
        menu.delegate = self

        statusSummaryItem = NSMenuItem(title: StatusMenuSummary.title(
            status: currentStatus,
            permissions: currentPermissions,
            pendingTranscript: currentPendingTranscript
        ), action: nil, keyEquivalent: "")
        statusSummaryItem.isEnabled = false
        menu.addItem(statusSummaryItem)
        menu.addItem(.separator())

        let launchAtLoginItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let launchAtLoginView = LaunchAtLoginMenuItemView(frame: NSRect(x: 0, y: 0, width: MenuRowMetrics.width, height: MenuRowMetrics.height))
        launchAtLoginView.onToggle = { [weak self] isOn in
            self?.setLaunchAtLoginEnabled(isOn)
        }
        launchAtLoginItem.view = launchAtLoginView
        menu.addItem(launchAtLoginItem)
        self.launchAtLoginItem = launchAtLoginItem
        self.launchAtLoginView = launchAtLoginView

        let settingsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let settingsItemView = MenuActionItemView(frame: NSRect(x: 0, y: 0, width: MenuRowMetrics.width, height: MenuRowMetrics.height))
        settingsItemView.configure(icon: Self.makeMenuIcon(systemName: "gearshape"), title: "Settings…")
        settingsItemView.onActivate = { [weak self] in
            self?.openSettings()
        }
        settingsItemView.update(isEnabled: true, toolTip: nil)
        settingsItem.view = settingsItemView
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "", action: nil, keyEquivalent: "q")
        let quitItemView = MenuActionItemView(frame: NSRect(x: 0, y: 0, width: MenuRowMetrics.width, height: MenuRowMetrics.height))
        quitItemView.configure(icon: Self.makeMenuIcon(systemName: "xmark.circle"), title: "Quit macSTT")
        quitItemView.onActivate = {
            NSApp.terminate(nil)
        }
        quitItemView.update(isEnabled: true, toolTip: nil)
        quitItem.view = quitItemView
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateStatusSummary()
        updateLaunchAtLoginMenuItem()
    }

    private func makeStatusIcon() -> NSImage {
        let size = NSSize(width: 28, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black,
            ]
            let text = NSAttributedString(string: "stt", attributes: attrs)
            let textSize = text.size()
            let origin = NSPoint(
                x: (rect.width - textSize.width) / 2,
                y: (rect.height - textSize.height) / 2
            )
            text.draw(at: origin)
            return true
        }
        image.isTemplate = true
        return image
    }

    private func updateStatusSummary() {
        statusSummaryItem?.title = StatusMenuSummary.title(
            status: currentStatus,
            permissions: currentPermissions,
            pendingTranscript: currentPendingTranscript
        )
    }

    private func updateLaunchAtLoginMenuItem() {
        guard let launchAtLoginItem, let launchAtLoginView else { return }
        guard isAppBundle else {
            launchAtLoginItem.isEnabled = false
            launchAtLoginView.update(
                isOn: false,
                isEnabled: false,
                toolTip: "Available only when macSTT is running from a bundled .app."
            )
            return
        }

        launchAtLoginItem.isEnabled = true

        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginView.update(isOn: true, isEnabled: true, toolTip: nil)
        case .requiresApproval:
            launchAtLoginView.update(
                isOn: true,
                isEnabled: true,
                toolTip: "Approve macSTT in System Settings > General > Login Items."
            )
        default:
            launchAtLoginView.update(isOn: false, isEnabled: true, toolTip: nil)
        }
    }

    private func startStateObservers() {
        statusTask?.cancel()
        statusTask = Task { @MainActor [weak self, sttActor] in
            self?.currentStatus = await sttActor.currentStatus
            self?.updateStatusSummary()

            for await status in sttActor.statusUpdates {
                guard !Task.isCancelled else { break }
                self?.currentStatus = status
                self?.updateStatusSummary()
            }
        }

        permissionTask?.cancel()
        permissionTask = Task { @MainActor [weak self, sttActor] in
            self?.currentPermissions = await sttActor.currentPermissions
            self?.updateStatusSummary()

            for await permissions in sttActor.permissionUpdates {
                guard !Task.isCancelled else { break }
                self?.currentPermissions = permissions
                self?.updateStatusSummary()
            }
        }

        pendingTranscriptTask?.cancel()
        pendingTranscriptTask = Task { @MainActor [weak self, sttActor] in
            self?.currentPendingTranscript = await sttActor.currentPendingTranscript
            self?.updateStatusSummary()

            for await pendingTranscript in sttActor.pendingTranscriptUpdates {
                guard !Task.isCancelled else { break }
                self?.currentPendingTranscript = pendingTranscript
                self?.updateStatusSummary()
            }
        }
    }

    private func setLaunchAtLoginEnabled(_ isEnabled: Bool, shouldOpenApprovalSettings: Bool = true) {
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }

            updateLaunchAtLoginMenuItem()
            if shouldOpenApprovalSettings, SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            updateLaunchAtLoginMenuItem()
            logger.error("Failed to update launch at login: \(error)")
        }
    }
}
