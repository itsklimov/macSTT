import CoreGraphics
import Foundation
import Logging

final class TriggerMonitor: @unchecked Sendable {

    enum EventHandlingResult: Equatable {
        case passThrough
        case consume
    }

    struct Activation {
        let deactivate: () -> Void
        let reEnable: () -> Void
    }

    private struct State {
        var triggers: [TriggerBinding]
        var isEnabled = true
        var activation: Activation?
    }

    fileprivate let handler: @Sendable () -> Void
    private let logger = Logger(label: "com.wixfi.stt.trigger-monitor")
    private let stateLock = NSLock()
    private let hasInputMonitoringAccess: () -> Bool
    private let createActivation: (UnsafeMutableRawPointer?) -> Activation?
    private var state: State

    init(
        triggers: [TriggerBinding],
        handler: @escaping @Sendable () -> Void,
        hasInputMonitoringAccess: @escaping () -> Bool = { CGPreflightListenEventAccess() },
        createActivation: @escaping (UnsafeMutableRawPointer?) -> Activation? = { userInfo in
            let eventMask: CGEventMask =
                (1 << CGEventType.keyDown.rawValue) |
                (1 << CGEventType.otherMouseDown.rawValue)

            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: triggerEventCallback,
                userInfo: userInfo
            ) else {
                return nil
            }

            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)

            return Activation(
                deactivate: {
                    CGEvent.tapEnable(tap: tap, enable: false)
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                },
                reEnable: {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            )
        }
    ) {
        self.state = State(triggers: triggers)
        self.handler = handler
        self.hasInputMonitoringAccess = hasInputMonitoringAccess
        self.createActivation = createActivation
    }

    func update(triggers: [TriggerBinding]) {
        withState { $0.triggers = triggers }
    }

    func setEnabled(_ isEnabled: Bool) {
        withState { $0.isEnabled = isEnabled }
    }

    @discardableResult
    func start() -> Bool {
        if withState({ $0.activation != nil }) {
            return true
        }

        guard hasInputMonitoringAccess() else {
            logger.error("Failed to create CGEvent tap — Input Monitoring permission is required")
            return false
        }

        guard let activation = createActivation(Unmanaged.passUnretained(self).toOpaque()) else {
            logger.error("Failed to create CGEvent tap")
            return false
        }

        let triggerCount = withState { state in
            state.activation = activation
            return state.triggers.count
        }
        logger.info("Trigger monitor started for \(triggerCount) trigger(s)")
        return true
    }

    func stop() {
        let activation = withState { state in
            let snapshot = state.activation
            state.activation = nil
            return snapshot
        }

        activation?.deactivate()
    }

    func handleInputEvent(
        type: CGEventType,
        keyCode: Int? = nil,
        modifiers: UInt = 0,
        buttonNumber: Int? = nil,
        isAutorepeat: Bool = false
    ) -> EventHandlingResult {
        let snapshot = withState { ($0.isEnabled, $0.triggers) }
        guard snapshot.0 else { return .passThrough }

        if type == .keyDown {
            guard !isAutorepeat else { return .passThrough }
            guard let keyCode else { return .passThrough }

            for trigger in snapshot.1 {
                if case .keyboard(let triggerKeyCode, let triggerModifiers) = trigger,
                   triggerKeyCode == keyCode,
                   triggerModifiers == modifiers {
                    handler()
                    return .consume
                }
            }
        }

        if type == .otherMouseDown {
            guard let buttonNumber else { return .passThrough }

            for trigger in snapshot.1 {
                if case .mouseButton(let triggerButton) = trigger, triggerButton == buttonNumber {
                    handler()
                    return .consume
                }
            }
        }

        return .passThrough
    }

    fileprivate func reEnableTapIfNeeded() {
        withState { $0.activation }?.reEnable()
    }

    fileprivate var isEnabledForCallback: Bool {
        withState { $0.isEnabled }
    }

    private func withState<T>(_ body: (inout State) -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body(&state)
    }
}

private func triggerEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<TriggerMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        monitor.reEnableTapIfNeeded()
        return Unmanaged.passUnretained(event)
    }

    guard monitor.isEnabledForCallback else { return Unmanaged.passUnretained(event) }
    let result = monitor.handleInputEvent(
        type: type,
        keyCode: type == .keyDown ? Int(event.getIntegerValueField(.keyboardEventKeycode)) : nil,
        modifiers: UInt(event.flags.rawValue) & TriggerBinding.modifierMask,
        buttonNumber: type == .otherMouseDown ? Int(event.getIntegerValueField(.mouseEventButtonNumber)) : nil,
        isAutorepeat: type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    )
    switch result {
    case .passThrough:
        return Unmanaged.passUnretained(event)
    case .consume:
        return nil
    }
}
