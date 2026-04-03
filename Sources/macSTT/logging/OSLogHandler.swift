import Logging
import OSLog

struct OSLogHandler: LogHandler {
    let osLogger: os.Logger
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .info

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    init(label: String) {
        self.osLogger = os.Logger(subsystem: label, category: "default")
    }

    func log(event: Logging.LogEvent) {
        log(
            level: event.level,
            message: event.message,
            metadata: event.metadata,
            source: event.source,
            file: event.file,
            function: event.function,
            line: event.line
        )
    }

    func log(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        metadata: Logging.Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let msg = "\(message)"
        switch level {
        case .trace, .debug: osLogger.debug("\(msg, privacy: .public)")
        case .info, .notice: osLogger.info("\(msg, privacy: .public)")
        case .warning: osLogger.warning("\(msg, privacy: .public)")
        case .error, .critical: osLogger.error("\(msg, privacy: .public)")
        }
    }
}
