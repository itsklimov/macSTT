import CoreAudio
import CoreGraphics
import Foundation
import Logging
import Testing
@testable import macSTT

private final class ListenerRegistrationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var added: [AudioDeviceMonitor.MonitoredProperty] = []
    private var removed: [AudioDeviceMonitor.MonitoredProperty] = []
    private let failingStatusByProperty: [AudioDeviceMonitor.MonitoredProperty: OSStatus]

    init(failingStatusByProperty: [AudioDeviceMonitor.MonitoredProperty: OSStatus] = [:]) {
        self.failingStatusByProperty = failingStatusByProperty
    }

    func add(_ property: AudioDeviceMonitor.MonitoredProperty, _ clientData: UnsafeMutableRawPointer?) -> OSStatus {
        lock.lock()
        added.append(property)
        lock.unlock()
        return failingStatusByProperty[property] ?? noErr
    }

    func remove(_ property: AudioDeviceMonitor.MonitoredProperty, _ clientData: UnsafeMutableRawPointer?) -> OSStatus {
        lock.lock()
        removed.append(property)
        lock.unlock()
        return noErr
    }

    func addedSnapshot() -> [AudioDeviceMonitor.MonitoredProperty] {
        lock.lock()
        defer { lock.unlock() }
        return added
    }

    func removedSnapshot() -> [AudioDeviceMonitor.MonitoredProperty] {
        lock.lock()
        defer { lock.unlock() }
        return removed
    }
}

private final class TriggerCountBox: @unchecked Sendable {
    var value = 0
}

private final class AccessStateBox: @unchecked Sendable {
    var isGranted: Bool

    init(isGranted: Bool) {
        self.isGranted = isGranted
    }
}

@Test func triggerMonitorConsumesKeyboardTriggerAndFiresHandler() {
    let triggerCount = TriggerCountBox()
    let monitor = TriggerMonitor(triggers: [.keyboard(keyCode: 126, modifiers: 0xC0000)]) {
        triggerCount.value += 1
    }

    let result = monitor.handleInputEvent(
        type: .keyDown,
        keyCode: 126,
        modifiers: 0xC0000,
        isAutorepeat: false
    )

    #expect(result == .consume)
    #expect(triggerCount.value == 1)
}

@Test func triggerMonitorConsumesMouseTriggerAndFiresHandler() {
    let triggerCount = TriggerCountBox()
    let monitor = TriggerMonitor(triggers: [.mouseButton(3)]) {
        triggerCount.value += 1
    }

    let result = monitor.handleInputEvent(
        type: .otherMouseDown,
        buttonNumber: 3
    )

    #expect(result == .consume)
    #expect(triggerCount.value == 1)
}

@Test func triggerMonitorPassesThroughWhenDisabled() {
    let triggerCount = TriggerCountBox()
    let monitor = TriggerMonitor(triggers: [.keyboard(keyCode: 126, modifiers: 0xC0000)]) {
        triggerCount.value += 1
    }
    monitor.setEnabled(false)

    let result = monitor.handleInputEvent(
        type: .keyDown,
        keyCode: 126,
        modifiers: 0xC0000,
        isAutorepeat: false
    )

    #expect(result == .passThrough)
    #expect(triggerCount.value == 0)
}

@Test func triggerMonitorRetriesStartAfterPermissionBecomesAvailable() {
    let accessState = AccessStateBox(isGranted: false)
    let activationCount = TriggerCountBox()
    let monitor = TriggerMonitor(
        triggers: [.keyboard(keyCode: 126, modifiers: 0xC0000)],
        handler: {},
        hasEventListeningAccess: { accessState.isGranted },
        createActivation: { _ in
            activationCount.value += 1
            return TriggerMonitor.Activation(
                deactivate: {},
                reEnable: {}
            )
        }
    )

    #expect(monitor.start() == false)
    #expect(activationCount.value == 0)

    accessState.isGranted = true

    #expect(monitor.start() == true)
    #expect(activationCount.value == 1)
    #expect(monitor.start() == true)
    #expect(activationCount.value == 1)
}

@Test func syntheticTypingPromptsAndThrowsWhenAccessibilityIsMissing() {
    var prompted = false
    var thrownError: SyntheticTypingError?
    var unexpectedError: String?

    do {
        try SyntheticTyping.requireAccessibilityPermission(
            isTrusted: { false },
            prompt: { prompted = true }
        )
    } catch let error as SyntheticTypingError {
        thrownError = error
    } catch {
        unexpectedError = String(describing: error)
    }

    #expect(prompted == true)
    #expect(unexpectedError == nil)
    #expect(thrownError == .accessibilityNotGranted)
}

@Test func syntheticTypingReportsGrantedAccessibilityWhenTrusted() {
    #expect(SyntheticTyping.hasAccessibilityPermission(isTrusted: { true }) == true)
    #expect(SyntheticTyping.hasAccessibilityPermission(isTrusted: { false }) == false)
}

@Test func syntheticTypingSplitsUtf16PayloadInto20CodeUnitChunks() {
    let chunks = SyntheticTyping.utf16Chunks(for: String(repeating: "a", count: 41))

    #expect(chunks.map(\.count) == [20, 20, 1])
}

@Test func syntheticTypingUsesKnownWorkingEventSemantics() {
    #expect(SyntheticTyping.insertionVirtualKey == 0x31)
    #expect(SyntheticTyping.insertionTapLocation == .cgAnnotatedSessionEventTap)
    #expect(SyntheticTyping.insertionSetsUnicodeOnKeyUp == false)
}

@Test func osLogHandlerStoresMetadataAndLogs() {
    var handler = OSLogHandler(label: "com.wixfi.stt.tests")

    handler[metadataKey: "scope"] = "tests"
    handler.log(
        level: .info,
        message: "hello",
        metadata: nil,
        source: "tests",
        file: #fileID,
        function: #function,
        line: #line
    )

    #expect(handler[metadataKey: "scope"] == "tests")
}

@Test func audioDeviceMonitorRollsBackPartialListenerRegistrationFailure() async {
    let recorder = ListenerRegistrationRecorder(
        failingStatusByProperty: [.devices: -50]
    )
    let monitor = AudioDeviceMonitor(
        addPropertyListener: recorder.add,
        removePropertyListener: recorder.remove
    )
    var thrownError: AudioDeviceMonitorError?
    var unexpectedError: String?

    do {
        try await monitor.startMonitoring()
    } catch let error as AudioDeviceMonitorError {
        thrownError = error
    } catch {
        unexpectedError = String(describing: error)
    }

    #expect(unexpectedError == nil)
    #expect(thrownError == .listenerRegistrationFailed(.devices, -50))
    #expect(recorder.addedSnapshot() == [.defaultInputDevice, .devices])
    #expect(recorder.removedSnapshot() == [.defaultInputDevice])

    await monitor.stopMonitoring()

    #expect(recorder.removedSnapshot() == [.defaultInputDevice])
}

@Test func bestExternalInputDeviceExcludesUnsupportedTransports() {
    let devices = [
        AudioDeviceMonitor.DeviceInfo(id: 1, name: "Built-in Mic", transport: "BuiltIn", isAlive: true, isRunning: false),
        AudioDeviceMonitor.DeviceInfo(id: 2, name: "Virtual Mic", transport: "Virtual", isAlive: true, isRunning: false),
        AudioDeviceMonitor.DeviceInfo(id: 3, name: "Aggregate Mic", transport: "Aggregate", isAlive: true, isRunning: false),
        AudioDeviceMonitor.DeviceInfo(id: 4, name: "Unknown Mic", transport: "Unknown(99)", isAlive: true, isRunning: false),
        AudioDeviceMonitor.DeviceInfo(id: 5, name: "USB Mic", transport: "USB", isAlive: true, isRunning: false),
    ]

    let best = AudioDeviceMonitor.selectBestExternalInputDevice(
        from: devices,
        defaultOutputName: nil
    ) { _ in 1 }

    #expect(best?.id == 5)
}

@Test func bestExternalInputDevicePrefersNonSpeakerCandidate() {
    let devices = [
        AudioDeviceMonitor.DeviceInfo(id: 10, name: "Studio Display", transport: "USB", isAlive: true, isRunning: false),
        AudioDeviceMonitor.DeviceInfo(id: 11, name: "USB Mic", transport: "USB", isAlive: true, isRunning: false),
    ]

    let best = AudioDeviceMonitor.selectBestExternalInputDevice(
        from: devices,
        defaultOutputName: "Studio Display"
    ) { deviceId in
        deviceId == 10 ? 2 : 1
    }

    #expect(best?.id == 11)
}

@Test func bestExternalInputDevicePrefersHigherChannelCount() {
    let devices = [
        AudioDeviceMonitor.DeviceInfo(id: 20, name: "Mono Mic", transport: "USB", isAlive: true, isRunning: false),
        AudioDeviceMonitor.DeviceInfo(id: 21, name: "Stereo Mic", transport: "USB", isAlive: true, isRunning: false),
    ]

    let best = AudioDeviceMonitor.selectBestExternalInputDevice(
        from: devices,
        defaultOutputName: nil
    ) { deviceId in
        deviceId == 20 ? 1 : 2
    }

    #expect(best?.id == 21)
}
