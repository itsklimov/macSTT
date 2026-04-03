import CoreAudio
import IOKit
import Logging

enum AudioDeviceMonitorError: LocalizedError, Equatable {
    case listenerRegistrationFailed(AudioDeviceMonitor.MonitoredProperty, OSStatus)

    var errorDescription: String? {
        switch self {
        case .listenerRegistrationFailed(let property, let status):
            "Failed to register \(property.label) listener (OSStatus: \(status))"
        }
    }
}

actor AudioDeviceMonitor {

    enum MonitoredProperty: CaseIterable, Equatable {
        case defaultInputDevice
        case devices

        var label: String {
            switch self {
            case .defaultInputDevice:
                "default input device"
            case .devices:
                "device list"
            }
        }

        var address: AudioObjectPropertyAddress {
            switch self {
            case .defaultInputDevice:
                AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultInputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
            case .devices:
                AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDevices,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
            }
        }
    }

    struct DeviceInfo: Sendable {
        let id: AudioDeviceID
        let name: String
        let transport: String
        let isAlive: Bool
        let isRunning: Bool
    }

    let deviceChanges: AsyncStream<AudioDeviceID>

    private let logger = Logger(label: "com.wixfi.stt.audio-device")
    private let continuation: AsyncStream<AudioDeviceID>.Continuation
    private let addPropertyListener: @Sendable (MonitoredProperty, UnsafeMutableRawPointer?) -> OSStatus
    private let removePropertyListener: @Sendable (MonitoredProperty, UnsafeMutableRawPointer?) -> OSStatus
    private var listenerRegistered = false
    private var retainedNotifier: Unmanaged<DeviceChangeNotifier>?

    init(
        addPropertyListener: @escaping @Sendable (MonitoredProperty, UnsafeMutableRawPointer?) -> OSStatus = AudioDeviceMonitor.liveAddPropertyListener,
        removePropertyListener: @escaping @Sendable (MonitoredProperty, UnsafeMutableRawPointer?) -> OSStatus = AudioDeviceMonitor.liveRemovePropertyListener
    ) {
        let (stream, cont) = AsyncStream<AudioDeviceID>.makeStream()
        self.deviceChanges = stream
        self.continuation = cont
        self.addPropertyListener = addPropertyListener
        self.removePropertyListener = removePropertyListener
    }

    // MARK: - Lifecycle

    func startMonitoring() throws {
        guard !listenerRegistered else { return }

        let notifier = DeviceChangeNotifier(continuation: continuation, logger: logger)
        let retained = Unmanaged.passRetained(notifier)
        let clientData = retained.toOpaque()
        var registeredProperties: [MonitoredProperty] = []

        do {
            for property in MonitoredProperty.allCases {
                let status = addPropertyListener(property, clientData)
                guard status == noErr else {
                    throw AudioDeviceMonitorError.listenerRegistrationFailed(property, status)
                }
                registeredProperties.append(property)
            }
        } catch {
            for property in registeredProperties.reversed() {
                let status = removePropertyListener(property, clientData)
                if status != noErr {
                    logger.error("Failed to remove \(property.label) listener during rollback (OSStatus: \(status))")
                }
            }
            retained.release()
            throw error
        }

        retainedNotifier = retained
        listenerRegistered = true

        if let device = Self.getDefaultInputDevice() {
            logger.info("Monitoring started on default input \"\(device.name)\"")
        } else {
            logger.warning("Monitoring started without a default input device")
        }
    }

    func stopMonitoring() {
        if listenerRegistered, let retained = retainedNotifier {
            let clientData = retained.toOpaque()

            for property in MonitoredProperty.allCases.reversed() {
                let status = removePropertyListener(property, clientData)
                if status != noErr {
                    logger.error("Failed to remove \(property.label) listener while stopping monitor (OSStatus: \(status))")
                }
            }

            retained.release()
            retainedNotifier = nil
            listenerRegistered = false
        }

        continuation.finish()
        logger.info("Monitoring stopped")
    }

    // MARK: - Static CoreAudio helpers

    private static func liveAddPropertyListener(
        _ property: MonitoredProperty,
        _ clientData: UnsafeMutableRawPointer?
    ) -> OSStatus {
        var address = property.address
        return AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            halPropertyListener,
            clientData
        )
    }

    private static func liveRemovePropertyListener(
        _ property: MonitoredProperty,
        _ clientData: UnsafeMutableRawPointer?
    ) -> OSStatus {
        var address = property.address
        return AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            halPropertyListener,
            clientData
        )
    }

    static func getDefaultInputDevice() -> DeviceInfo? {
        var deviceId = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &deviceId
        )
        guard status == noErr, deviceId != kAudioObjectUnknown else { return nil }

        let name = getDeviceName(deviceId) ?? "Unknown"
        let transport = getTransportType(deviceId)
        let alive = getIsAlive(deviceId)
        let running = getIsRunning(deviceId)
        return DeviceInfo(id: deviceId, name: name, transport: transport, isAlive: alive, isRunning: running)
    }

    static func getAllInputDevices() -> [DeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIds = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIds
        ) == noErr else { return [] }

        return deviceIds.compactMap { id in
            guard getChannelCount(id, scope: kAudioObjectPropertyScopeInput) > 0 else { return nil }

            let name = getDeviceName(id) ?? "Unknown"
            let transport = getTransportType(id)
            let alive = getIsAlive(id)
            let running = getIsRunning(id)
            return DeviceInfo(id: id, name: name, transport: transport, isAlive: alive, isRunning: running)
        }
    }

    // MARK: - Clamshell & device selection

    static func isClamshellClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        guard let prop = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        ) else { return false }
        return prop.takeRetainedValue() as? Bool ?? false
    }

    @discardableResult
    static func setDefaultInputDevice(_ deviceId: AudioDeviceID) -> Bool {
        var id = deviceId
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id
        ) == noErr
    }

    static func bestExternalInputDevice() -> DeviceInfo? {
        selectBestExternalInputDevice(
            from: getAllInputDevices(),
            defaultOutputName: getDefaultOutputDeviceName()
        ) {
            getChannelCount($0, scope: kAudioObjectPropertyScopeInput)
        }
    }

    static func selectBestExternalInputDevice(
        from devices: [DeviceInfo],
        defaultOutputName: String?,
        channelCount: (AudioDeviceID) -> Int
    ) -> DeviceInfo? {
        let skip: Set<String> = ["BuiltIn", "Virtual", "Aggregate"]
        var candidates = devices.filter { device in
            device.isAlive && !skip.contains(device.transport) && !device.transport.starts(with: "Unknown")
        }
        guard !candidates.isEmpty else { return nil }

        let nonSpeakers = candidates.filter { $0.name != defaultOutputName }
        if !nonSpeakers.isEmpty {
            candidates = nonSpeakers
        }

        candidates.sort { channelCount($0.id) > channelCount($1.id) }
        return candidates.first
    }

    private static func getDefaultOutputDeviceName() -> String? {
        var deviceId = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceId
        ) == noErr, deviceId != kAudioObjectUnknown else { return nil }
        return getDeviceName(deviceId)
    }


    // MARK: - Device property queries

    private static func getDeviceName(_ deviceId: AudioDeviceID) -> String? {
        getStringProperty(deviceId, selector: kAudioDevicePropertyDeviceNameCFString)
    }

    private static func getTransportType(_ deviceId: AudioDeviceID) -> String {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceId, &address, 0, nil, &size, &transport) == noErr else {
            return "query-failed"
        }
        switch transport {
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "BluetoothLE"
        case kAudioDeviceTransportTypeBuiltIn: return "BuiltIn"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        default: return "Unknown(\(transport))"
        }
    }

    private static func getChannelCount(_ deviceId: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceId, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBuffer.deallocate() }
        guard AudioObjectGetPropertyData(deviceId, &address, 0, nil, &size, rawBuffer) == noErr else { return 0 }
        let bufferList = rawBuffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func getStringProperty(_ deviceId: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceId, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }

    private static func getIsAlive(_ deviceId: AudioDeviceID) -> Bool {
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceId, &address, 0, nil, &size, &alive) == noErr else {
            return false
        }
        return alive != 0
    }

    private static func getIsRunning(_ deviceId: AudioDeviceID) -> Bool {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceId, &address, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }
}

// MARK: - C callback bridge

private final class DeviceChangeNotifier: Sendable {
    let continuation: AsyncStream<AudioDeviceID>.Continuation
    let logger: Logger

    init(continuation: AsyncStream<AudioDeviceID>.Continuation, logger: Logger) {
        self.continuation = continuation
        self.logger = logger
    }
}

private func halPropertyListener(
    _ objectID: AudioObjectID,
    _ numberAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let notifier = Unmanaged<DeviceChangeNotifier>.fromOpaque(clientData).takeUnretainedValue()
    let logger = notifier.logger

    if let device = AudioDeviceMonitor.getDefaultInputDevice() {
        logger.info("Default input changed to \"\(device.name)\"")
        notifier.continuation.yield(device.id)
    } else {
        logger.warning("Default input changed, but no default input device is available")
    }
    return noErr
}
