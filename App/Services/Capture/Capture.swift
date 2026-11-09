import AVFoundation
import AppKit
import Foundation
import OSLog
import Ontology
import ScreenCaptureKit

private let log = Logger.service("capture")

private let cameraCaptureHeadroom: TimeInterval = 10
private let screenshotTimeout: Duration = .seconds(10)
/// `record(forDuration:)` stops on its own; the file is read this long after
/// `duration`, so the recorder has finished writing it.
private let audioReadDelay: TimeInterval = 0.5
private let audioTimeoutHeadroom: TimeInterval = 5

private let maxCaptureDimension = 4096

/// A display or window identifier, which is a `UInt32`. Converting an
/// arbitrary client integer with `UInt32(_:)` traps, so this is the only
/// conversion.
func captureIdentifier(_ key: String, description: String) -> ToolArgument<UInt32?> {
    ToolArgument(key, .integer(description: description, minimum: 0)) { present in
        guard let present else { return nil }
        guard let identifier = present.wholeNumberValue.flatMap({ UInt32(exactly: $0) }) else {
            throw ToolInputError("\(key) must be a whole number between 0 and \(UInt32.max)")
        }
        return identifier
    }
}

actor CameraPhotoCaptureGate {
    static let shared = CameraPhotoCaptureGate()

    private var inFlight = false

    func perform<T>(_ work: () async throws -> T) async throws -> T {
        guard !inFlight else {
            throw ToolFailure("Camera capture already in progress")
        }
        inFlight = true
        defer { inFlight = false }
        return try await work()
    }
}

final class CaptureService: NSObject, Service {
    static let shared = CaptureService()

    var permission: ServicePermission { .capture }

    override init() {
        super.init()
        log.debug("Initializing capture service")
    }

    deinit {
        log.info("Deinitializing capture service")
    }

    /// Any one of the three grants is enough to call the service usable.
    var isActivated: Bool {
        get async {
            AVCaptureDevice.authorizationStatus(for: .video) == .authorized
                || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                || CGPreflightScreenCaptureAccess()
        }
    }

    /// Checks only. Each tool requests the permission it needs; do not call
    /// `requestAccess` or `CGRequestScreenCaptureAccess` from here.
    func activate() async throws {
        guard await isActivated else {
            throw ToolFailure("No Camera, Microphone, or Screen Recording access")
        }
    }

    private func requestPermission(for mediaType: AVMediaType) async throws {
        let mediaName = mediaType == .video ? "Camera" : "Microphone"
        let status = AVCaptureDevice.authorizationStatus(for: mediaType)
        if status == .authorized { return }
        if status == .notDetermined, await AVCaptureDevice.requestAccess(for: mediaType) { return }
        log.error("\(mediaName) access not granted")
        throw ServicePermission.notGranted(mediaName, pane: mediaName)
    }

    private func requestScreenRecordingPermission() async throws {
        if CGPreflightScreenCaptureAccess() { return }
        guard CGRequestScreenCaptureAccess() else {
            throw ServicePermission.notGranted(
                "Screen recording",
                pane: "Screen & System Audio Recording",
                note: "iMCP may need a restart afterwards."
            )
        }
    }

    private static let pictureFormat = ToolArgument<ImageFormat>.choice("format", default: .default)
    private static let pictureQuality = ToolArgument.number(
        "quality",
        description: "JPEG compression quality, 0 smallest to 1 best. Ignored when format is png.",
        default: ImageFormat.defaultJPEGQuality,
        in: 0 ... 1
    )
    private static let preset = ToolArgument<SessionPreset>.choice(
        "preset",
        description: "Camera quality preset",
        default: .default
    )
    private static let device = ToolArgument<CaptureDeviceType>.choice(
        "device",
        description: "Camera device type",
        default: .default
    )
    private static let position = ToolArgument<CaptureDevicePosition>.choice(
        "position",
        description: "Camera position",
        default: .default
    )
    private static let flash = ToolArgument<FlashMode>.choice("flash", description: "Flash mode", default: .default)
    private static let autoExposure = ToolArgument.bool(
        "autoExposure",
        description: "Enable automatic exposure and light balancing",
        default: true
    )
    private static let autoFocus = ToolArgument.bool(
        "autoFocus",
        description: "Enable automatic focus",
        default: true
    )
    private static let autoWhiteBalance = ToolArgument.bool(
        "autoWhiteBalance",
        description: "Enable automatic white balance",
        default: true
    )
    private static let delay = ToolArgument.number(
        "delay",
        description: "Seconds to wait after the camera starts before the shutter fires",
        default: 1,
        in: 0 ... 60
    )
    private static let maxDimension = ToolArgument.integer(
        "maxDimension",
        description: ArgumentDescription.maxDimension,
        default: 2048,
        in: 1 ... maxCaptureDimension
    )

    private static let audioFormat = ToolArgument<AudioFormat>.choice("format", default: .default)
    private static let duration = ToolArgument.number(
        "duration",
        description: "Recording duration in seconds",
        default: 10,
        in: 1 ... 300
    )
    private static let audioQuality = ToolArgument<AudioQuality>.choice(
        "quality",
        description: "Encoding quality: low is 22.05 kHz mono, medium 44.1 kHz mono, high 44.1 kHz stereo",
        default: .default
    )

    private static let contentType = ToolArgument<ScreenCaptureContentType>.choice(
        "contentType",
        description: "What to capture. The other arguments needed depend on this.",
        default: .default
    )
    private static let screenshotFormat = ToolArgument<ImageFormat>.choice("format", default: .default)
    private static let screenshotQuality = ToolArgument<ScreenCaptureQuality>.choice(
        "quality",
        description:
            "Capture resolution as a multiple of the display size: low 0.5x, medium 0.75x, high 1x, max 2x",
        default: .default
    )
    private static let displayID = captureIdentifier(
        "displayId",
        description: "Display to capture when contentType is \"display\". Defaults to the first display."
    )
    private static let windowID = captureIdentifier(
        "windowId",
        description: "Window to capture. Required when contentType is \"window\"."
    )
    private static let bundleID = ToolArgument.string(
        "bundleId",
        description: "Bundle identifier of the app to capture. Required when contentType is \"application\"."
    )
    private static let includesCursor = ToolArgument.bool(
        "includesCursor",
        description: "Draw the mouse pointer into the screenshot",
        default: true
    )

    var tools: [Tool] {
        Tool(
            name: "capture_take_picture",
            description: "Take a photo with a camera attached to this Mac and return the image data",
            arguments: [
                Self.pictureFormat, Self.pictureQuality, Self.preset, Self.device, Self.position, Self.flash,
                Self.autoExposure, Self.autoFocus, Self.autoWhiteBalance, Self.delay, Self.maxDimension,
            ],
            annotations: .init(
                title: "Take Picture",
                readOnlyHint: false,
                destructiveHint: false,
                openWorldHint: false
            )
        ) { arguments in
            try await CameraPhotoCaptureGate.shared.perform {
                try await self.capturePicture(arguments: arguments)
            }
        }

        Tool(
            name: "capture_record_audio",
            description: "Record from the microphone for a fixed duration and return the audio data",
            arguments: [Self.audioFormat, Self.duration, Self.audioQuality],
            annotations: .init(
                title: "Record Audio",
                readOnlyHint: false,
                destructiveHint: false,
                openWorldHint: false
            )
        ) { arguments in
            try await self.requestPermission(for: .audio)

            let format = try Self.audioFormat(arguments)
            let duration = try Self.duration(arguments)
            let quality = try Self.audioQuality(arguments)

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(format.fileExtension)

            let settings = quality.recorderSettings

            let recorder = try AVAudioRecorder(url: tempURL, settings: settings)
            recorder.record(forDuration: duration)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            return try await withDeadline(
                .seconds(duration + audioTimeoutHeadroom),
                throwing: ToolFailure("Audio recording timeout"),
                onTimeout: { recorder.stop() }
            ) {
                do {
                    try await Task.sleep(for: .seconds(duration + audioReadDelay))
                    recorder.stop()
                    return Value.data(mimeType: format.mimeType, try Data(contentsOf: tempURL))
                } catch {
                    recorder.stop()
                    throw error
                }
            }
        }

        Tool(
            name: "capture_take_screenshot",
            description:
                "Capture a display, a single window, or one application's windows, and return the image",
            arguments: [
                Self.contentType, Self.screenshotFormat, Self.screenshotQuality, Self.displayID, Self.windowID,
                Self.bundleID, Self.includesCursor, Self.maxDimension,
            ],
            annotations: .init(
                title: "Take Screenshot",
                readOnlyHint: false,
                destructiveHint: false,
                openWorldHint: false
            )
        ) { arguments in
            try await self.requestScreenRecordingPermission()

            let contentType = try Self.contentType(arguments)
            let format = try Self.screenshotFormat(arguments)
            let quality = try Self.screenshotQuality(arguments)
            let includesCursor = try Self.includesCursor(arguments)
            let maxDimension = try Self.maxDimension(arguments)
            let displayId = try Self.displayID(arguments)
            let windowId = try Self.windowID(arguments)
            let bundleId = try Self.bundleID(arguments)

            let availableContent = try await SCShareableContent.getAvailableContent()

            // Remember which display (if any) the captured content actually lives on, so the
            // output is sized from it below rather than from an unrelated
            // `availableContent.displays.first`.
            let contentFilter: SCContentFilter
            var sizingDisplay: SCDisplay?
            switch contentType {
            case .display:
                let display: SCDisplay
                if let displayId = displayId {
                    guard
                        let selectedDisplay = availableContent.displays.first(where: {
                            $0.displayID == displayId
                        })
                    else {
                        throw ToolFailure("Display not found")
                    }
                    display = selectedDisplay
                } else {
                    guard let mainDisplay = availableContent.displays.first else {
                        throw ToolFailure("No displays available")
                    }
                    display = mainDisplay
                }
                sizingDisplay = display
                let excludedWindows = availableContent.windows.filter {
                    $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
                }
                contentFilter = SCContentFilter(display: display, excludingWindows: excludedWindows)

            case .window:
                guard let windowId = windowId else {
                    throw ToolInputError("Window ID required for window capture")
                }
                guard
                    let window = availableContent.windows.first(where: { $0.windowID == windowId })
                else {
                    throw ToolFailure("Window not found")
                }
                // Window capture isn't tied to a single display; size from the primary display.
                sizingDisplay = availableContent.displays.first
                contentFilter = SCContentFilter(desktopIndependentWindow: window)

            case .application:
                guard let bundleId = bundleId else {
                    throw ToolInputError("Bundle ID required for application capture")
                }
                guard
                    let application = availableContent.applications.first(where: {
                        $0.bundleIdentifier == bundleId
                    })
                else {
                    throw ToolFailure("Application not found")
                }
                let appWindows = availableContent.windows.filter {
                    $0.owningApplication == application
                }
                guard let firstDisplay = availableContent.displays.first else {
                    throw ToolFailure("No displays available for application capture")
                }
                sizingDisplay = firstDisplay
                contentFilter = SCContentFilter(
                    display: firstDisplay,
                    including: appWindows
                )
            }

            let streamConfiguration = SCStreamConfiguration()
            streamConfiguration.capturesAudio = false
            streamConfiguration.showsCursor = includesCursor
            streamConfiguration.scalesToFit = true
            streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA

            if let display = sizingDisplay {
                let scaledWidth = Int(CGFloat(display.width) * quality.scaleFactor)
                let scaledHeight = Int(CGFloat(display.height) * quality.scaleFactor)
                let clamped = clampedImageDimensions(
                    width: scaledWidth,
                    height: scaledHeight,
                    maxDimension: maxDimension
                )
                streamConfiguration.width = clamped.width
                streamConfiguration.height = clamped.height
            }

            return try await withDeadline(screenshotTimeout, throwing: ToolFailure("Screenshot capture timeout")) {
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: contentFilter,
                    configuration: streamConfiguration
                )

                guard let imageData = format.encode(image) else {
                    throw ToolFailure("Failed to create \(format == .png ? "PNG" : "JPEG") data")
                }
                return Value.data(mimeType: format.mimeType, imageData)
            }
        }

    }

    private func capturePicture(arguments: [String: Value]) async throws -> Value {
        try await requestPermission(for: .video)

        let format = try Self.pictureFormat(arguments)
        let quality = try Self.pictureQuality(arguments)
        let preset = try Self.preset(arguments)
        let device = try Self.device(arguments)
        let position = try Self.position(arguments)
        let flash = try Self.flash(arguments)
        let autoExposure = try Self.autoExposure(arguments)
        let autoFocus = try Self.autoFocus(arguments)
        let autoWhiteBalance = try Self.autoWhiteBalance(arguments)
        let delay = try Self.delay(arguments)
        let maxDimension = try Self.maxDimension(arguments)

        let captureSession = AVCaptureSession()
        captureSession.sessionPreset = preset.avPreset

        guard let camera = AVCaptureDevice.camera(for: device, position: position) else {
            throw ToolFailure("No camera device found")
        }

        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }

        if autoExposure && camera.isExposureModeSupported(.autoExpose) {
            camera.exposureMode = .autoExpose
        }

        if autoFocus && camera.isFocusModeSupported(.autoFocus) {
            camera.focusMode = .autoFocus
        }

        if autoWhiteBalance && camera.isWhiteBalanceModeSupported(.autoWhiteBalance) {
            camera.whiteBalanceMode = .autoWhiteBalance
        }

        let videoInput = try AVCaptureDeviceInput(device: camera)
        guard captureSession.canAddInput(videoInput) else {
            throw ToolFailure("Cannot add video input")
        }
        captureSession.addInput(videoInput)

        let photoOutput = AVCapturePhotoOutput()
        guard captureSession.canAddOutput(photoOutput) else {
            throw ToolFailure("Cannot add photo output")
        }
        captureSession.addOutput(photoOutput)

        // AVCapturePhotoOutput keeps a weak delegate reference; retain
        // across the async delay/capture until the callback or timeout.
        let delegateHolder = PhotoCaptureDelegateHolder()
        return try await withDeadline(
            .seconds(delay + cameraCaptureHeadroom),
            throwing: ToolFailure("Camera capture timeout"),
            onTimeout: {
                await MainActor.run {
                    delegateHolder.delegate = nil
                    captureSession.stopRunning()
                }
            }
        ) { report in
            captureSession.startRunning()

            _ = Task { @MainActor in
                if delay > 0 {
                    try await Task.sleep(for: .seconds(delay))
                }

                let settings = AVCapturePhotoSettings()
                if photoOutput.supportedFlashModes.contains(flash.avFlashMode) {
                    settings.flashMode = flash.avFlashMode
                }

                let delegate = PhotoCaptureDelegate(
                    format: format,
                    quality: quality,
                    maxDimension: maxDimension,
                    completion: { result in
                        Task { @MainActor in
                            captureSession.stopRunning()
                            delegateHolder.delegate = nil
                            report(result)
                        }
                    }
                )
                delegateHolder.delegate = delegate

                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }
}

// MARK: - Photo Capture Delegate

private final class PhotoCaptureDelegateHolder {
    var delegate: PhotoCaptureDelegate?
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let format: ImageFormat
    private let quality: Double
    private let maxDimension: Int
    private let completion: (Result<Value, Error>) -> Void

    init(
        format: ImageFormat,
        quality: Double,
        maxDimension: Int,
        completion: @escaping (Result<Value, Error>) -> Void
    ) {
        self.format = format
        self.quality = quality
        self.maxDimension = maxDimension
        self.completion = completion
        super.init()
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error = error {
            completion(.failure(error))
            return
        }

        guard let imageData = photo.fileDataRepresentation() else {
            completion(
                .failure(ToolFailure("Failed to get image data"))
            )
            return
        }

        guard let image = NSImage(data: imageData),
            let encoded = format.encode(clampedImage(image, maxDimension: maxDimension), jpegQuality: quality)
        else {
            completion(.failure(ToolFailure("Failed to convert to \(format == .png ? "PNG" : "JPEG")")))
            return
        }
        completion(.success(.data(mimeType: format.mimeType, encoded)))
    }
}
