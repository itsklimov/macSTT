import AppKit

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private static let minimumWindowWidth: CGFloat = 440
    private static let maximumWindowWidth: CGFloat = 480
    private static let minimumWindowHeight: CGFloat = 360
    private static let defaultWindowHeight: CGFloat = 460

    private let window: NSWindow

    init(contentViewController: NSViewController) {
        _ = contentViewController.view

        let windowFrame = Self.initialWindowFrame(for: contentViewController.view)
        let window = NSWindow(
            contentRect: windowFrame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "macSTT"
        window.minSize = NSSize(width: Self.minimumWindowWidth, height: Self.minimumWindowHeight)
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

    private func syncActivationPolicy() {
        let targetPolicy: NSApplication.ActivationPolicy = window.isVisible ? .regular : .accessory
        guard NSApp.activationPolicy() != targetPolicy else { return }
        NSApp.setActivationPolicy(targetPolicy)
    }

    private static func initialWindowFrame(for contentView: NSView) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(
                x: 0,
                y: 0,
                width: minimumWindowWidth,
                height: defaultWindowHeight
            )
        }

        let screenFrame = screen.visibleFrame
        let maxWindowWidth = min(screenFrame.width / 3, maximumWindowWidth)
        let fittingSize = contentView.fittingSize
        let contentWidth = max(minimumWindowWidth, min(maxWindowWidth, fittingSize.width))
        let contentHeight = max(minimumWindowHeight, min(screenFrame.height * 0.75, fittingSize.height))

        return NSRect(
            x: screenFrame.maxX - contentWidth,
            y: screenFrame.maxY - contentHeight - 40,
            width: contentWidth,
            height: contentHeight
        )
    }
}
