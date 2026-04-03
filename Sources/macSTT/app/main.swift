import AppKit
import Logging

LoggingSystem.bootstrap {
    MultiplexLogHandler([
        OSLogHandler(label: $0),
        StreamLogHandler.standardError(label: $0),
    ])
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
