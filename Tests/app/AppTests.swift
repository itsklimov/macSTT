import AppKit
import ServiceManagement
import Testing
@testable import macSTT

private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let suiteName = "macSTTAppTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    try body(defaults)
}

@Test @MainActor func appDelegateUsesMenuBarLifecycleDefaults() {
    let delegate = AppDelegate()

    #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared) == false)
    #expect(delegate.applicationSupportsSecureRestorableState(NSApplication.shared) == true)
}

@Test func appAboutPanelShowsTaglineAndVersionMetadata() {
    let options = AppAboutPanel.options(
        appName: "macSTT",
        shortVersion: "0.0.14",
        buildVersion: "14"
    )

    #expect(options[.applicationName] as? String == "macSTT")
    #expect(options[.applicationVersion] as? String == "0.0.14")
    #expect(options[.version] as? String == "14")
    #expect((options[.credits] as? NSAttributedString)?.string == "Private, local speech-to-text for macOS.")
    #expect(options[.applicationIcon] is NSImage)
}

@Test func appAboutPanelFallsBackToProjectMetadataForDevRuns() {
    let projectYAML = """
    PRODUCT_NAME: "macSTT"
    MARKETING_VERSION: "0.0.14"
    CURRENT_PROJECT_VERSION: "14"
    """

    let metadata = AppAboutPanel.projectMetadata(from: projectYAML)
    #expect(metadata.appName == "macSTT")
    #expect(metadata.shortVersion == "0.0.14")
    #expect(metadata.buildVersion == "14")
}

@Test func appAboutPanelPrefersLargestProjectIconAsset() throws {
    let temporaryDirectoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let appIconSetURL = temporaryDirectoryURL
        .appendingPathComponent("Sources/macSTT/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

    try FileManager.default.createDirectory(at: appIconSetURL, withIntermediateDirectories: true)
    try Data().write(to: appIconSetURL.appendingPathComponent("icon_512x512.png"))
    try Data().write(to: appIconSetURL.appendingPathComponent("icon_512x512@2x.png"))
    try Data().write(to: appIconSetURL.appendingPathComponent("icon_1024x1024.png"))

    defer {
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
    }

    let iconURL = AppAboutPanel.projectIconAssetURL(projectRootURL: temporaryDirectoryURL)

    #expect(iconURL?.lastPathComponent == "icon_1024x1024.png")
}

@Test func appLaunchBehaviorOpensSettingsWhenPermissionsAreMissing() {
    #expect(
        AppLaunchBehavior.shouldOpenSettingsOnLaunch(
            for: PermissionSnapshot(microphone: .granted, accessibility: .granted),
            shouldShowReadyAfterPermissionRelaunch: false
        ) == false
    )
    #expect(
        AppLaunchBehavior.shouldOpenSettingsOnLaunch(
            for: PermissionSnapshot(microphone: .notDetermined, accessibility: .granted),
            shouldShowReadyAfterPermissionRelaunch: false
        ) == true
    )
    #expect(
        AppLaunchBehavior.shouldOpenSettingsOnLaunch(
            for: PermissionSnapshot(microphone: .granted, accessibility: .denied),
            shouldShowReadyAfterPermissionRelaunch: false
        ) == true
    )
    #expect(
        AppLaunchBehavior.shouldOpenSettingsOnLaunch(
            for: PermissionSnapshot(microphone: .granted, accessibility: .granted),
            shouldShowReadyAfterPermissionRelaunch: true
        ) == true
    )
}

@Test func appLaunchBehaviorConsumesReadyAfterPermissionRelaunchFlag() {
    withIsolatedDefaults { defaults in
        #expect(AppLaunchBehavior.consumeReadyAfterPermissionRelaunch(defaults: defaults) == false)

        AppLaunchBehavior.markReadyAfterPermissionRelaunch(defaults: defaults)

        #expect(AppLaunchBehavior.consumeReadyAfterPermissionRelaunch(defaults: defaults) == true)
        #expect(AppLaunchBehavior.consumeReadyAfterPermissionRelaunch(defaults: defaults) == false)
    }
}

@Test func launchAtLoginPolicyRegistersOnlyAfterPermissionRelaunch() {
    #expect(
        LaunchAtLoginRegistrationPolicy.shouldRegisterAfterPermissionRelaunch(
            isAppBundle: true,
            status: .notRegistered,
            didCompletePermissionRelaunch: true
        ) == true
    )
    #expect(
        LaunchAtLoginRegistrationPolicy.shouldRegisterAfterPermissionRelaunch(
            isAppBundle: false,
            status: .notRegistered,
            didCompletePermissionRelaunch: true
        ) == false
    )
    #expect(
        LaunchAtLoginRegistrationPolicy.shouldRegisterAfterPermissionRelaunch(
            isAppBundle: true,
            status: .enabled,
            didCompletePermissionRelaunch: true
        ) == false
    )
    #expect(
        LaunchAtLoginRegistrationPolicy.shouldRegisterAfterPermissionRelaunch(
            isAppBundle: true,
            status: .requiresApproval,
            didCompletePermissionRelaunch: true
        ) == false
    )
    #expect(
        LaunchAtLoginRegistrationPolicy.shouldRegisterAfterPermissionRelaunch(
            isAppBundle: true,
            status: .notRegistered,
            didCompletePermissionRelaunch: false
        ) == false
    )
}

@Test func permissionRelaunchPromptAppearsWhenVisiblePermissionsBecomeReady() {
    #expect(
        AppPermissionRelaunchPrompt.shouldPrompt(
            previous: PermissionSnapshot(microphone: .granted, accessibility: .notDetermined),
            current: PermissionSnapshot(microphone: .granted, accessibility: .granted),
            hasAlreadyPrompted: false
        ) == true
    )
    #expect(
        AppPermissionRelaunchPrompt.shouldPrompt(
            previous: PermissionSnapshot(microphone: .granted, accessibility: .granted),
            current: PermissionSnapshot(microphone: .granted, accessibility: .granted),
            hasAlreadyPrompted: false
        ) == false
    )
    #expect(
        AppPermissionRelaunchPrompt.shouldPrompt(
            previous: PermissionSnapshot(microphone: .granted, accessibility: .notDetermined),
            current: PermissionSnapshot(microphone: .granted, accessibility: .granted),
            hasAlreadyPrompted: true
        ) == false
    )
}

@Test func appRelauncherBuildsWaitAndOpenScript() {
    let script = AppRelauncher.relaunchScript(
        bundlePath: "/Applications/mac'STT.app",
        processIdentifier: 1234
    )

    #expect(script.contains("/bin/kill -0 1234"))
    #expect(script.contains("/usr/bin/open -n '/Applications/mac'\\''STT.app'"))
}

@Test @MainActor func appActivationPolicyUsesRegularModeForVisibleWindowsAndUpdates() {
    #expect(
        AppActivationPolicy.target(settingsWindowVisible: false, sparkleUpdateSessionActive: false) == .accessory
    )
    #expect(
        AppActivationPolicy.target(settingsWindowVisible: true, sparkleUpdateSessionActive: false) == .regular
    )
    #expect(
        AppActivationPolicy.target(settingsWindowVisible: false, sparkleUpdateSessionActive: true) == .regular
    )
}

@Test @MainActor func settingsWindowUsesFixedWidth() {
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 460))
    let screenFrame = NSRect(x: 0, y: 0, width: 1600, height: 1000)

    let windowFrame = SettingsWindowController.initialWindowFrame(
        for: contentView,
        screenVisibleFrame: screenFrame
    )

    #expect(windowFrame.width == 400)
    #expect(windowFrame.width == SettingsWindowController.fixedWindowWidth)
}

@Test func sparkleSupportStaysDisabledWithoutOfficialBuildSettings() {
    #expect(
        SparkleSupport.isEnabled(
            infoDictionary: [
                "MacSTTEnableSparkle": "NO",
                "SUFeedURL": "https://example.com/appcast.xml",
                "SUPublicEDKey": "pubkey"
            ]
        ) == false
    )
}

@Test func sparkleSupportRequiresFeedAndPublicKey() {
    #expect(
        SparkleSupport.isEnabled(
            infoDictionary: [
                "MacSTTEnableSparkle": "YES",
                "SUPublicEDKey": "pubkey"
            ]
        ) == false
    )
    #expect(
        SparkleSupport.isEnabled(
            infoDictionary: [
                "MacSTTEnableSparkle": "YES",
                "SUFeedURL": "https://example.com/appcast.xml"
            ]
        ) == false
    )
    #expect(
        SparkleSupport.isEnabled(
            infoDictionary: [
                "MacSTTEnableSparkle": "YES",
                "SUFeedURL": "https://example.com/appcast.xml",
                "SUPublicEDKey": "pubkey"
            ]
        ) == true
    )
}

@Test func sparkleSupportLaunchCheckRequiresAutomaticChecksEnabled() {
    #expect(SparkleSupport.shouldPerformInitialUpdateCheck(automaticallyChecksForUpdates: true) == true)
    #expect(SparkleSupport.shouldPerformInitialUpdateCheck(automaticallyChecksForUpdates: false) == false)
}
