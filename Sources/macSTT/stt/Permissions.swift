enum PermissionState: String, Sendable, Equatable {
    case granted
    case notDetermined
    case denied

    var displayName: String {
        switch self {
        case .granted:
            "Granted"
        case .notDetermined:
            "Not Requested"
        case .denied:
            "Denied"
        }
    }
}

struct PermissionSnapshot: Sendable, Equatable {
    var microphone: PermissionState
    var inputMonitoring: PermissionState
    var accessibility: PermissionState

    var allGranted: Bool {
        microphone == .granted &&
        inputMonitoring == .granted &&
        accessibility == .granted
    }

    var requiresAttention: Bool {
        !allGranted
    }
}
