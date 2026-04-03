enum SttModelBackend: Sendable, Equatable {
    case cpu
    case neuralEngine

    var displayName: String {
        switch self {
        case .cpu:
            "CPU"
        case .neuralEngine:
            "Neural Engine"
        }
    }
}

enum SttPreparationPhase: Sendable, Equatable {
    case checkingModelCache(language: SttLanguage)
    case downloadingModels(language: SttLanguage, completedFiles: Int, totalFiles: Int)
    case loadingModels(language: SttLanguage, backend: SttModelBackend, detail: String, percent: Int)
}

struct SttStatusPresentation: Sendable, Equatable {
    var title: String
    var detail: String?
    var progressPercent: Int?
    var showsProgress: Bool
    var isProgressIndeterminate: Bool
    var isError: Bool

    var summaryText: String {
        if let progressPercent {
            return "\(title) (\(progressPercent)%)"
        }
        return title
    }
}

enum SttStatus: Sendable, Equatable {
    case idle(detail: String)
    case preparing(SttPreparationPhase)
    case ready
    case error(String)

    var canStartCapture: Bool {
        self == .ready
    }

    var hasLoadedModels: Bool {
        switch self {
        case .ready:
            true
        case .idle, .preparing, .error:
            false
        }
    }

    var isPreparing: Bool {
        if case .preparing = self { return true }
        return false
    }

    var presentation: SttStatusPresentation {
        switch self {
        case .idle(let detail):
            return SttStatusPresentation(
                title: "Initializing",
                detail: detail,
                progressPercent: nil,
                showsProgress: false,
                isProgressIndeterminate: false,
                isError: false
            )
        case .preparing(let phase):
            switch phase {
            case .checkingModelCache(let language):
                return SttStatusPresentation(
                    title: "Checking Models",
                    detail: "\(language.displayName) model cache",
                    progressPercent: nil,
                    showsProgress: true,
                    isProgressIndeterminate: true,
                    isError: false
                )
            case .downloadingModels(let language, let completedFiles, let totalFiles):
                let percent = totalFiles == 0 ? 0 : Int((Double(completedFiles) / Double(totalFiles)) * 90.0)
                return SttStatusPresentation(
                    title: "Downloading Models",
                    detail: "\(language.displayName) model • \(completedFiles)/\(totalFiles) files",
                    progressPercent: percent,
                    showsProgress: true,
                    isProgressIndeterminate: false,
                    isError: false
                )
            case .loadingModels(let language, let backend, let detail, let percent):
                return SttStatusPresentation(
                    title: "Loading Models",
                    detail: "\(language.displayName) model on \(backend.displayName) • \(detail)",
                    progressPercent: percent,
                    showsProgress: true,
                    isProgressIndeterminate: false,
                    isError: false
                )
            }
        case .ready:
            return SttStatusPresentation(
                title: "Ready",
                detail: nil,
                progressPercent: nil,
                showsProgress: false,
                isProgressIndeterminate: false,
                isError: false
            )
        case .error(let message):
            return SttStatusPresentation(
                title: "Error",
                detail: message,
                progressPercent: nil,
                showsProgress: false,
                isProgressIndeterminate: false,
                isError: true
            )
        }
    }
}
