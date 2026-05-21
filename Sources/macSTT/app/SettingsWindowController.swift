import AppKit

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let fixedWindowWidth: CGFloat = 400
    private static let minimumWindowHeight: CGFloat = 240
    private static let defaultWindowHeight: CGFloat = 300

    private let window: NSWindow

    var isVisible: Bool {
        window.isVisible
    }

    init(contentViewController: NSViewController) {
        _ = contentViewController.view

        let windowFrame = Self.initialWindowFrame(for: contentViewController.view)
        let window = NSWindow(
            contentRect: windowFrame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.minSize = NSSize(width: Self.fixedWindowWidth, height: Self.minimumWindowHeight)
        window.maxSize = NSSize(width: Self.fixedWindowWidth, height: .greatestFiniteMagnitude)
        window.isReleasedWhenClosed = false
        window.contentViewController = contentViewController
        self.window = window

        super.init()
        self.window.delegate = self
    }

    func open() {
        NSApp.setActivationPolicy(.regular)
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            self.syncActivationPolicy()
        }
    }

    func syncActivationPolicy() {
        let targetPolicy: NSApplication.ActivationPolicy = window.isVisible ? .regular : .accessory
        guard NSApp.activationPolicy() != targetPolicy else { return }
        NSApp.setActivationPolicy(targetPolicy)
    }

    private static func initialWindowFrame(for contentView: NSView) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(
                x: 0,
                y: 0,
                width: fixedWindowWidth,
                height: defaultWindowHeight
            )
        }

        return initialWindowFrame(for: contentView, screenVisibleFrame: screen.visibleFrame)
    }

    static func initialWindowFrame(for contentView: NSView, screenVisibleFrame: NSRect) -> NSRect {
        let fittingSize = contentView.fittingSize
        let contentHeight = max(minimumWindowHeight, min(screenVisibleFrame.height * 0.75, fittingSize.height))

        return NSRect(
            x: screenVisibleFrame.maxX - fixedWindowWidth,
            y: screenVisibleFrame.maxY - contentHeight - 40,
            width: fixedWindowWidth,
            height: contentHeight
        )
    }
}
