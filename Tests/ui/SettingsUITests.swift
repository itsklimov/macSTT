import AppKit
import Testing
@testable import macSTT

private final class LockedPermissionSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: PermissionSnapshot

    init(_ snapshot: PermissionSnapshot) {
        self.snapshot = snapshot
    }

    func current() -> PermissionSnapshot {
        lock.withLock { snapshot }
    }

    func set(_ snapshot: PermissionSnapshot) {
        lock.withLock {
            self.snapshot = snapshot
        }
    }
}

@MainActor private func makeSettingsViewController(
    permissionSnapshot: @escaping @Sendable () -> PermissionSnapshot = {
        PermissionSnapshot(
            microphone: .granted,
            accessibility: .notDetermined
        )
    },
    requestMicrophonePermission: @escaping @Sendable () async -> Bool = { false }
) -> SettingsViewController {
    let actor = SttActor(
        environment: SttEnvironment(
            permissionSnapshot: permissionSnapshot,
            requestMicrophonePermission: requestMicrophonePermission,
            promptAccessibilityPermission: {},
            typeTextAtCursor: { _ in },
            loadPendingTranscript: { nil },
            savePendingTranscript: { _ in }
        )
    )

    return SettingsViewController(
        sttActor: actor,
        initialConfig: SttConfig(language: .english, triggers: [])
    )
}

@MainActor private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
    var matches = [T]()
    if let match = view as? T {
        matches.append(match)
    }
    for subview in view.subviews {
        matches.append(contentsOf: descendants(of: type, in: subview))
    }
    return matches
}

@MainActor private func visibleTextValues(in view: NSView) -> [String] {
    descendants(of: NSTextField.self, in: view)
        .filter { !$0.isHidden }
        .map(\.stringValue)
}

@MainActor private func visibleButtonTitles(in view: NSView) -> [String] {
    descendants(of: NSButton.self, in: view)
        .filter { !$0.isHidden }
        .map(\.title)
}

@Test @MainActor func triggerRecorderUsesInjectedInitialTriggers() {
    let expectedTriggers: [TriggerBinding] = [
        .keyboard(keyCode: 126, modifiers: 0xC0000),
        .mouseButton(4),
    ]

    let recorder = TriggerRecorderView(initialTriggers: expectedTriggers)

    #expect(recorder.triggers == expectedTriggers)
}

@Test @MainActor func triggerRecorderRemovesIndexedTrigger() {
    let initialTriggers: [TriggerBinding] = [
        .keyboard(keyCode: 126, modifiers: 0xC0000),
        .mouseButton(3),
        .keyboard(keyCode: 125, modifiers: 0x40000),
    ]
    let recorder = TriggerRecorderView(initialTriggers: initialTriggers)
    var changeCount = 0
    recorder.onTriggerChanged = {
        changeCount += 1
    }

    recorder.removeTrigger(at: 1)
    recorder.removeTrigger(at: 99)

    #expect(recorder.triggers == [
        .keyboard(keyCode: 126, modifiers: 0xC0000),
        .keyboard(keyCode: 125, modifiers: 0x40000),
    ])
    #expect(changeCount == 1)
}

@Test @MainActor func settingsUsesGroupedNativeRows() throws {
    let controller = makeSettingsViewController()
    let rootView = controller.view
    rootView.layoutSubtreeIfNeeded()

    _ = try #require(rootView as? NSStackView)
    let groups = descendants(of: NSBox.self, in: rootView).filter { $0.boxType == .custom }

    #expect(groups.count >= 3)
    #expect(groups.allSatisfy { $0.cornerRadius == 8 })
    #expect(groups.allSatisfy { $0.borderWidth == 0 })
}

@Test @MainActor func settingsLanguageUsesSegmentedControl() throws {
    let controller = makeSettingsViewController()
    let rootView = controller.view
    rootView.layoutSubtreeIfNeeded()

    let languageControl = try #require(descendants(of: NSSegmentedControl.self, in: rootView).first)

    #expect(languageControl.segmentCount == 2)
    #expect(languageControl.label(forSegment: 0) == "English")
    #expect(languageControl.label(forSegment: 1) == "Multilingual")
    #expect(languageControl.selectedSegment == 0)
}

@Test @MainActor func settingsPrimaryRowsRemainVisible() throws {
    let controller = makeSettingsViewController()
    let rootView = controller.view
    rootView.layoutSubtreeIfNeeded()

    let textValues = visibleTextValues(in: rootView)

    for title in ["Settings", "Trigger", "Language", "Microphone", "Accessibility", "Model"] {
        #expect(textValues.contains(title))
    }
    #expect(!textValues.contains("General"))
    #expect(!textValues.contains("Permissions"))
    #expect(!textValues.contains("Status"))
    #expect(!textValues.contains("macSTT"))
    #expect(!textValues.contains("Input Monitoring"))
    #expect(!textValues.contains("Activation"))
}

@Test @MainActor func settingsUsesOnlyHeaderIcon() throws {
    let controller = makeSettingsViewController()
    let rootView = controller.view
    rootView.layoutSubtreeIfNeeded()

    #expect(descendants(of: NSImageView.self, in: rootView).count == 1)
}

@Test @MainActor func settingsPermissionRowsShowStateAndActions() async throws {
    let controller = makeSettingsViewController()
    let rootView = controller.view
    var textValues = [String]()
    var buttonTitles = [String]()

    for _ in 0..<20 {
        rootView.layoutSubtreeIfNeeded()
        textValues = visibleTextValues(in: rootView)
        buttonTitles = visibleButtonTitles(in: rootView)
        if textValues.contains("Granted"), buttonTitles.contains("Allow") {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(textValues.contains("Granted"))
    #expect(textValues.contains("Not Requested"))
    #expect(buttonTitles.contains("Allow"))
}

@Test @MainActor func settingsPollsPermissionStateChanges() async throws {
    let permissions = LockedPermissionSnapshot(
        PermissionSnapshot(microphone: .notDetermined, accessibility: .granted)
    )
    let controller = makeSettingsViewController(
        permissionSnapshot: { permissions.current() }
    )
    let rootView = controller.view

    permissions.set(PermissionSnapshot(microphone: .granted, accessibility: .granted))

    var textValues = [String]()
    var buttonTitles = [String]()
    for _ in 0..<20 {
        rootView.layoutSubtreeIfNeeded()
        textValues = visibleTextValues(in: rootView)
        buttonTitles = visibleButtonTitles(in: rootView)
        if textValues.filter({ $0 == "Granted" }).count >= 2, !buttonTitles.contains("Allow") {
            break
        }
        try await Task.sleep(for: .milliseconds(100))
    }

    #expect(textValues.filter { $0 == "Granted" }.count >= 2)
    #expect(!buttonTitles.contains("Allow"))
}
