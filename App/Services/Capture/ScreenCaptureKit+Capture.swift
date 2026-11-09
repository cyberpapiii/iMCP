import ScreenCaptureKit

enum ScreenCaptureContentType: String, Hashable, CaseIterable {
    static let `default`: ScreenCaptureContentType = .display

    case display = "display"
    case window = "window"
    case application = "application"
}

enum ScreenCaptureQuality: String, Hashable, CaseIterable {
    static let `default`: ScreenCaptureQuality = .medium

    case low = "low"
    case medium = "medium"
    case high = "high"
    case max = "max"

    var scaleFactor: CGFloat {
        switch self {
        case .low:
            return 0.5
        case .medium:
            return 0.75
        case .high:
            return 1.0
        case .max:
            return 2.0
        }
    }
}

extension SCShareableContent {
    static func getAvailableContent() async throws -> SCShareableContent {
        return try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
    }
}
