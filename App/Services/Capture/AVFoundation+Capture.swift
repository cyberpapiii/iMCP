import AVFoundation

enum CaptureDeviceType: String, Hashable, CaseIterable {
    static let `default`: CaptureDeviceType = .builtInWideAngle

    case builtInWideAngle = "built-in"
    case continuity = "continuity"
    case external = "external"
    case deskView = "desk-view"

    var avDeviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .builtInWideAngle:
            return .builtInWideAngleCamera
        case .continuity:
            return .continuityCamera
        case .deskView:
            return .deskViewCamera
        case .external:
            return .external
        }
    }
}

enum CaptureDevicePosition: String, Hashable, CaseIterable {
    static let `default`: CaptureDevicePosition = .unspecified

    case unspecified = "unspecified"
    case back = "back"
    case front = "front"

    var avPosition: AVCaptureDevice.Position {
        switch self {
        case .unspecified:
            return .unspecified
        case .back:
            return .back
        case .front:
            return .front
        }
    }
}

enum FlashMode: String, Hashable, CaseIterable {
    static let `default`: FlashMode = .auto

    case auto = "auto"
    case on = "on"
    case off = "off"

    var avFlashMode: AVCaptureDevice.FlashMode {
        switch self {
        case .auto:
            return .auto
        case .on:
            return .on
        case .off:
            return .off
        }
    }
}

enum SessionPreset: String, Hashable, CaseIterable {
    static let `default`: SessionPreset = .photo

    case photo = "photo"
    case low = "low"
    case medium = "medium"
    case high = "high"
    case hd1280x720 = "hd1280x720"
    case hd1920x1080 = "hd1920x1080"
    case hd4K3840x2160 = "hd4K3840x2160"

    var avPreset: AVCaptureSession.Preset {
        switch self {
        case .photo:
            return .photo
        case .low:
            return .low
        case .medium:
            return .medium
        case .high:
            return .high
        case .hd1280x720:
            return .hd1280x720
        case .hd1920x1080:
            return .hd1920x1080
        case .hd4K3840x2160:
            return .hd4K3840x2160
        }
    }
}

enum AudioQuality: String, Hashable, CaseIterable {
    static let `default`: AudioQuality = .medium

    case low = "low"
    case medium = "medium"
    case high = "high"

    var recorderSettings: [String: Any] {
        switch self {
        case .low:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 22050,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.low.rawValue,
            ]
        case .medium:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
        case .high:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
        }
    }
}

enum AudioFormat: String, Hashable, CaseIterable {
    static let `default`: AudioFormat = .mp4

    case mp4 = "mp4"
    case caf = "caf"

    var fileExtension: String {
        return rawValue
    }

    var mimeType: String {
        switch self {
        case .mp4:
            return "audio/mp4"
        case .caf:
            return "audio/x-caf"
        }
    }
}

extension AVCaptureDevice {
    static func camera(for deviceType: CaptureDeviceType, position: CaptureDevicePosition) -> AVCaptureDevice? {
        // Ask for the requested type at every position, including .unspecified.
        // Macs report external, Continuity, and Desk View cameras at
        // .unspecified, and .unspecified is also this tool's default position,
        // so short-circuiting it made those three types unreachable unless the
        // caller also guessed .front or .back.
        if let device = AVCaptureDevice.default(
            deviceType.avDeviceType,
            for: .video,
            position: position.avPosition
        ) {
            return device
        }

        // The requested device type is not attached; keep the position and
        // settle for the built-in camera.
        if let builtIn = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: position.avPosition
        ) {
            return builtIn
        }

        return AVCaptureDevice.default(for: .video)
    }
}
