import AppKit
import Logging
import Sparkle

enum AppAboutPanel {
    static func options(bundle: Bundle = .main) -> [NSApplication.AboutPanelOptionKey: Any] {
        let metadata = resolvedMetadata(bundle: bundle)
        return options(
            appName: metadata.appName,
            shortVersion: metadata.shortVersion,
            buildVersion: metadata.buildVersion,
            icon: resolvedIcon(bundle: bundle)
        )
    }

    static func options(
        appName: String,
        shortVersion: String,
        buildVersion: String,
        icon: NSImage = fallbackIcon()
    ) -> [NSApplication.AboutPanelOptionKey: Any] {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: appName,
            .applicationIcon: icon,
            .credits: credits(for: "Private, local speech-to-text for macOS.")
        ]

        if !shortVersion.isEmpty {
            options[.applicationVersion] = shortVersion
        }

        if !buildVersion.isEmpty {
            options[.version] = buildVersion
        }

        return options
    }

    private static func resolvedMetadata(bundle: Bundle) -> (appName: String, shortVersion: String, buildVersion: String) {
        let bundleAppName = sanitized(bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? sanitized(bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String)
        let bundleShortVersion = sanitized(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let bundleBuildVersion = sanitized(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)

        if let bundleShortVersion, let bundleBuildVersion {
            return (
                appName: bundleAppName ?? ProcessInfo.processInfo.processName,
                shortVersion: bundleShortVersion,
                buildVersion: bundleBuildVersion
            )
        }

        let projectFallback = projectMetadata()
        return (
            appName: bundleAppName ?? projectFallback.appName ?? ProcessInfo.processInfo.processName,
            shortVersion: bundleShortVersion ?? projectFallback.shortVersion ?? "",
            buildVersion: bundleBuildVersion ?? projectFallback.buildVersion ?? ""
        )
    }

    static func projectMetadata(from projectYAML: String) -> (appName: String?, shortVersion: String?, buildVersion: String?) {
        (
            extract(projectYAML, pattern: /PRODUCT_NAME:\s*"([^"]+)"/),
            extract(projectYAML, pattern: /MARKETING_VERSION:\s*"([^"]+)"/),
            extract(projectYAML, pattern: /CURRENT_PROJECT_VERSION:\s*"([^"]+)"/)
        )
    }

    private static func projectMetadata() -> (appName: String?, shortVersion: String?, buildVersion: String?) {
        guard let projectYAML = loadProjectYAML() else {
            return (nil, nil, nil)
        }

        return projectMetadata(from: projectYAML)
    }

    private static func loadProjectYAML() -> String? {
        guard let projectRootURL else {
            return nil
        }

        let candidateURL = projectRootURL.appendingPathComponent("project.yml")
        return try? String(contentsOf: candidateURL, encoding: .utf8)
    }

    private static func extract(_ string: String, pattern: Regex<(Substring, Substring)>) -> String? {
        guard let match = string.firstMatch(of: pattern) else { return nil }
        return String(match.1)
    }

    private static func sanitized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.contains("$(") ? nil : trimmed
    }

    private static func resolvedIcon(bundle: Bundle) -> NSImage {
        if let applicationIcon = bundleIcon(bundle: bundle) {
            return applicationIcon
        }

        if let projectIcon = projectIcon() {
            return projectIcon
        }

        return fallbackIcon()
    }

    private static func credits(for text: String) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineSpacing = 2

        return NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraphStyle
            ]
        )
    }

    private static func bundleIcon(bundle: Bundle) -> NSImage? {
        guard bundle.bundleURL.pathExtension == "app" else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: bundle.bundlePath)
        guard icon.isValid else {
            return nil
        }
        return icon
    }

    private static func projectIcon() -> NSImage? {
        guard let iconURL = projectIconAssetURL() else {
            return nil
        }

        return NSImage(contentsOf: iconURL)
    }

    static func projectIconAssetURL(
        fileManager: FileManager = .default,
        projectRootURL: URL? = projectRootURL
    ) -> URL? {
        guard let projectRootURL else {
            return nil
        }

        let appIconSetURL = projectRootURL
            .appendingPathComponent("Sources/macSTT/Assets.xcassets")
            .appendingPathComponent("AppIcon.appiconset")

        guard
            let assetURLs = try? fileManager.contentsOfDirectory(
                at: appIconSetURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }

        return assetURLs
            .filter { $0.pathExtension.lowercased() == "png" }
            .max { projectIconSortKey(for: $0) < projectIconSortKey(for: $1) }
    }

    private static func projectIconSortKey(for url: URL) -> (Int, Int, String) {
        let fileName = url.deletingPathExtension().lastPathComponent.lowercased()
        let scale = fileName.contains("@2x") ? 2 : 1
        let logicalSize = fileName.firstMatch(of: /(\d+)x(\d+)/).flatMap { match in
            Int(match.1)
        } ?? 0

        return (logicalSize * scale, logicalSize, fileName)
    }

    private static var projectRootURL: URL? {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var directoryURL = executableURL.deletingLastPathComponent()

        for _ in 0..<6 {
            let candidateURL = directoryURL.appendingPathComponent("project.yml")
            if FileManager.default.fileExists(atPath: candidateURL.path) {
                return directoryURL
            }
            directoryURL.deleteLastPathComponent()
        }

        let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidateURL = currentDirectoryURL.appendingPathComponent("project.yml")
        guard FileManager.default.fileExists(atPath: candidateURL.path) else {
            return nil
        }

        return currentDirectoryURL
    }

    private static func fallbackIcon() -> NSImage {
        let size = NSSize(width: 128, height: 128)
        let image = NSImage(size: size, flipped: false) { rect in
            let insetRect = rect.insetBy(dx: 10, dy: 10)
            let backgroundPath = NSBezierPath(roundedRect: insetRect, xRadius: 28, yRadius: 28)
            NSColor.windowBackgroundColor.setFill()
            backgroundPath.fill()

            NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
            backgroundPath.lineWidth = 1
            backgroundPath.stroke()

            guard let symbol = NSImage(
                systemSymbolName: "waveform.badge.mic",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(.init(pointSize: 44, weight: .regular)) else {
                return true
            }

            let symbolSize = symbol.size
            let symbolRect = NSRect(
                x: rect.midX - symbolSize.width / 2,
                y: rect.midY - symbolSize.height / 2,
                width: symbolSize.width,
                height: symbolSize.height
            )

            NSColor.labelColor.set()
            symbol.draw(in: symbolRect)
            return true
        }
        image.isTemplate = false
        return image
    }
}

enum AppLaunchBehavior {
    static func shouldOpenSettingsOnLaunch(for permissions: PermissionSnapshot) -> Bool {
        permissions.requiresAttention
    }
}

enum SparkleSupport {
    static func isEnabled(bundle: Bundle = .main) -> Bool {
        isEnabled(infoDictionary: bundle.infoDictionary ?? [:])
    }

    static func isEnabled(infoDictionary: [String: Any]) -> Bool {
        guard
            sanitized(infoDictionary["MacSTTEnableSparkle"] as? String) == "YES",
            sanitized(infoDictionary["SUFeedURL"] as? String) != nil,
            sanitized(infoDictionary["SUPublicEDKey"] as? String) != nil
        else {
            return false
        }

        return true
    }

    @MainActor
    static func makeUpdaterController(bundle: Bundle = .main) -> SPUStandardUpdaterController? {
        guard isEnabled(bundle: bundle) else {
            return nil
        }

        return SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    private static func sanitized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }

        return trimmed.contains("$(") ? nil : trimmed
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sttActor: SttActor?
    private var settingsWindowController: SettingsWindowController?
    private var statusItemController: StatusItemController?
    private var triggerMonitor: TriggerMonitor?

    private let logger = Logger(label: "com.wixfi.stt.app")
    private let updaterController = SparkleSupport.makeUpdaterController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupApplication()
        refreshPermissionState()
        presentSettingsIfNeededOnLaunch()

        logger.info("Sparkle updater \(self.updaterController == nil ? "disabled" : "enabled") for this build")
        logger.info("macSTT launched")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshPermissionState()
        syncTriggerMonitor(with: SttConfig.load())
        statusItemController?.refreshLaunchAtLoginState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItemController?.shutdown()
        stopTriggerMonitor()
        guard let actor = sttActor else { return }
        sttActor = nil
        Task {
            await actor.shutdown()
        }
    }

    private func setupApplication() {
        let config = SttConfig.load()
        let actor = SttActor(language: config.language)
        let settingsViewController = SettingsViewController(sttActor: actor, initialConfig: config)
        settingsViewController.onConfigChanged = { [weak self] config in
            self?.handleSttConfigChange(config)
        }
        settingsViewController.onRecordingChanged = { [weak self] recording in
            self?.triggerMonitor?.setEnabled(!recording)
        }

        sttActor = actor
        settingsWindowController = SettingsWindowController(contentViewController: settingsViewController)
        statusItemController = StatusItemController(
            sttActor: actor,
            openAbout: { [weak self] in
                self?.showAboutPanel(nil)
            },
            openSettings: { [weak self] in
                self?.openSettings()
            }
        )

        syncTriggerMonitor(with: config)

        Task {
            await actor.prepare()
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(title: "About macSTT", action: #selector(showAboutPanel(_:)), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(withTitle: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit macSTT", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        NSApp.mainMenu = mainMenu
    }

    private func presentSettingsIfNeededOnLaunch() {
        guard let actor = sttActor else { return }
        Task { @MainActor [weak self, actor] in
            let permissions = await actor.currentPermissions
            guard AppLaunchBehavior.shouldOpenSettingsOnLaunch(for: permissions) else { return }
            self?.openSettings()
        }
    }

    private func refreshPermissionState() {
        guard let actor = sttActor else { return }
        Task {
            await actor.refreshPermissionState()
        }
    }

    @objc private func openSettings() {
        settingsWindowController?.open()
        refreshPermissionState()
    }

    @objc private func showAboutPanel(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: AppAboutPanel.options())
    }

    private func syncTriggerMonitor(with config: SttConfig) {
        if let triggerMonitor {
            triggerMonitor.update(triggers: config.triggers)
            triggerMonitor.setEnabled(true)
            _ = triggerMonitor.start()
            return
        }

        guard let actor = sttActor else { return }

        let monitor = TriggerMonitor(triggers: config.triggers) { [weak self, actor] in
            Task(priority: .userInitiated) { [weak self, actor] in
                let result = await actor.toggleCaptureFromTrigger()
                guard result == .blockedByPermissions else { return }
                await MainActor.run { [weak self] in
                    self?.openSettings()
                }
            }
        }
        _ = monitor.start()
        triggerMonitor = monitor
    }

    private func stopTriggerMonitor() {
        triggerMonitor?.setEnabled(false)
        triggerMonitor?.stop()
        triggerMonitor = nil
    }

    private func handleSttConfigChange(_ config: SttConfig) {
        syncTriggerMonitor(with: config)
        guard let actor = sttActor else { return }
        Task { [weak self] in
            do {
                try await actor.switchLanguage(config.language)
            } catch {
                self?.logger.error("Failed to switch STT language: \(error)")
            }
        }
    }
}
