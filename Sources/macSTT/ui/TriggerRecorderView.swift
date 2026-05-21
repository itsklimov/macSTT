import AppKit

@MainActor
final class TriggerRecorderView: NSView {

    var onTriggerChanged: (() -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    private(set) var triggers: [TriggerBinding] = []

    private let pillStack = NSStackView()
    private let addButton: NSButton = {
        let btn = NSButton(title: "+", target: nil, action: nil)
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.font = .systemFont(ofSize: 14, weight: .medium)
        btn.setContentHuggingPriority(.required, for: .horizontal)
        return btn
    }()

    private var isRecording = false
    private var keyMonitor: Any?
    private var mouseMonitor: Any?

    init(initialTriggers: [TriggerBinding]) {
        self.triggers = initialTriggers
        super.init(frame: .zero)
        setup()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override var intrinsicContentSize: NSSize {
        let fittingSize = pillStack.fittingSize
        return NSSize(width: fittingSize.width, height: max(24, fittingSize.height))
    }

    private func setup() {
        pillStack.orientation = .horizontal
        pillStack.spacing = 6
        pillStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pillStack)
        NSLayoutConstraint.activate([
            pillStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            pillStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            pillStack.topAnchor.constraint(equalTo: topAnchor),
            pillStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])

        addButton.target = self
        addButton.action = #selector(addClicked)
        rebuildPills()
    }

    func setTriggers(_ triggers: [TriggerBinding]) {
        self.triggers = triggers
        if !isRecording {
            rebuildPills()
        }
    }

    private func rebuildPills() {
        pillStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for (index, trigger) in triggers.enumerated() {
            pillStack.addArrangedSubview(makePill(for: trigger, index: index))
        }

        if isRecording {
            pillStack.addArrangedSubview(makeRecordingPill())
        } else {
            pillStack.addArrangedSubview(addButton)
        }
        invalidateIntrinsicContentSize()
    }

    private func makePill(for trigger: TriggerBinding, index: Int) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
        container.layer?.cornerRadius = 10

        let label = NSTextField(labelWithString: trigger.displayName)
        label.font = .systemFont(ofSize: 12)

        let closeBtn = NSButton(title: "×", target: self, action: #selector(removePill(_:)))
        closeBtn.bezelStyle = .inline
        closeBtn.isBordered = false
        closeBtn.font = .systemFont(ofSize: 12, weight: .medium)
        closeBtn.setContentHuggingPriority(.required, for: .horizontal)
        closeBtn.tag = index

        let stack = NSStackView(views: [label, closeBtn])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    private func makeRecordingPill() -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.controlAccentColor.cgColor

        let dot = NSTextField(labelWithString: "●")
        dot.font = .systemFont(ofSize: 8)
        dot.textColor = .controlAccentColor

        let label = NSTextField(labelWithString: "Press key or click...")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [dot, label])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    @objc private func addClicked() {
        startRecording()
    }

    @objc private func removePill(_ sender: NSButton) {
        removeTrigger(at: sender.tag)
    }

    func removeTrigger(at index: Int) {
        guard triggers.indices.contains(index) else { return }
        triggers.remove(at: index)
        rebuildPills()
        onTriggerChanged?()
    }

    private func startRecording() {
        isRecording = true
        onRecordingChanged?(true)
        rebuildPills()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.stopRecording()
                return nil
            }
            let keyCode = Int(event.keyCode)
            let modifiers = UInt(event.modifierFlags.rawValue) & TriggerBinding.modifierMask
            let binding = TriggerBinding.keyboard(keyCode: keyCode, modifiers: modifiers)
            if !self.triggers.contains(binding) {
                self.triggers.append(binding)
            }
            self.stopRecording()
            self.onTriggerChanged?()
            return nil
        }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self else { return event }
            let binding = TriggerBinding.mouseButton(event.buttonNumber)
            if !self.triggers.contains(binding) {
                self.triggers.append(binding)
            }
            self.stopRecording()
            self.onTriggerChanged?()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        onRecordingChanged?(false)
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        rebuildPills()
    }
}
