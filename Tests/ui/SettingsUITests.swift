import AppKit
import Testing
@testable import macSTT

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
