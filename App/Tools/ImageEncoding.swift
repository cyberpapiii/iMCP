import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ImageFormat: String, Hashable, CaseIterable {
    static let `default`: ImageFormat = .jpeg
    static let defaultJPEGQuality = 0.8

    case jpeg = "jpeg"
    case png = "png"

    var mimeType: String {
        switch self {
        case .jpeg:
            return "image/jpeg"
        case .png:
            return "image/png"
        }
    }

    private var type: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        }
    }

    /// Nil when ImageIO cannot encode it. `jpegQuality` is ignored for PNG.
    func encode(_ image: CGImage, jpegQuality: Double = ImageFormat.defaultJPEGQuality) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any]? =
            self == .jpeg ? [kCGImageDestinationLossyCompressionQuality: jpegQuality] : nil
        CGImageDestinationAddImage(destination, image, options as CFDictionary?)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Encodes the image's pixels, not its size in points, which on a Retina
    /// display is half as many.
    func encode(_ image: NSImage, jpegQuality: Double = ImageFormat.defaultJPEGQuality) -> Data? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap { encode($0, jpegQuality: jpegQuality) }
    }
}

func clampedImageDimensions(width: Int, height: Int, maxDimension: Int) -> (width: Int, height: Int) {
    guard maxDimension > 0 else { return (width, height) }
    let largestSide = max(width, height)
    guard largestSide > maxDimension else { return (width, height) }
    let scale = Double(maxDimension) / Double(largestSide)
    let scaledWidth = max(1, Int((Double(width) * scale).rounded()))
    let scaledHeight = max(1, Int((Double(height) * scale).rounded()))
    return (scaledWidth, scaledHeight)
}

/// Rasterize via `NSBitmapImageRep` rather than `NSImage.lockFocus()`, which
/// allocates at the screen's backing scale (2x on Retina) and would defeat `maxDimension`.
func clampedImage(_ image: NSImage, maxDimension: Int) -> NSImage {
    guard let representation = image.representations.first else { return image }
    let pixelWidth = representation.pixelsWide
    let pixelHeight = representation.pixelsHigh
    guard pixelWidth > 0, pixelHeight > 0 else { return image }

    let target = clampedImageDimensions(width: pixelWidth, height: pixelHeight, maxDimension: maxDimension)
    guard target.width != pixelWidth || target.height != pixelHeight else { return image }

    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: target.width,
            pixelsHigh: target.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    else { return image }
    rep.size = NSSize(width: target.width, height: target.height)

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        NSGraphicsContext.restoreGraphicsState()
        return image
    }
    NSGraphicsContext.current = context
    image.draw(
        in: NSRect(x: 0, y: 0, width: CGFloat(target.width), height: CGFloat(target.height)),
        from: .zero,
        operation: .copy,
        fraction: 1.0
    )
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    let resized = NSImage(size: NSSize(width: target.width, height: target.height))
    resized.addRepresentation(rep)
    return resized
}
