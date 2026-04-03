import AppKit
import Testing
@testable import macSTT

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
            for: PermissionSnapshot(microphone: .granted, inputMonitoring: .granted, accessibility: .granted)
        ) == false
    )
    #expect(
        AppLaunchBehavior.shouldOpenSettingsOnLaunch(
            for: PermissionSnapshot(microphone: .notDetermined, inputMonitoring: .granted, accessibility: .granted)
        ) == true
    )
    #expect(
        AppLaunchBehavior.shouldOpenSettingsOnLaunch(
            for: PermissionSnapshot(microphone: .granted, inputMonitoring: .granted, accessibility: .denied)
        ) == true
    )
    #expect(
        AppLaunchBehavior.shouldOpenSettingsOnLaunch(
            for: PermissionSnapshot(microphone: .granted, inputMonitoring: .denied, accessibility: .granted)
        ) == true
    )
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
