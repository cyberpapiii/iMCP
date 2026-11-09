import AppKit
import XCTest

@testable import iMCP

final class ImageEncodingTests: XCTestCase {
    func testClampedDimensionsScalesDownToLargestSide() {
        let result = clampedImageDimensions(width: 4000, height: 2000, maxDimension: 2000)
        XCTAssertEqual(result.width, 2000)
        XCTAssertEqual(result.height, 1000)
    }

    func testClampedDimensionsNeverScalesUp() {
        let result = clampedImageDimensions(width: 800, height: 600, maxDimension: 2048)
        XCTAssertEqual(result.width, 800)
        XCTAssertEqual(result.height, 600)
    }

    func testClampedDimensionsClampsSquareInput() {
        let result = clampedImageDimensions(width: 3000, height: 3000, maxDimension: 1000)
        XCTAssertEqual(result.width, 1000)
        XCTAssertEqual(result.height, 1000)
    }

    func testClampedDimensionsClampsPortraitOnTallAxis() {
        // Height is the larger side here, so height should hit maxDimension and width
        // should scale with it. Clamping on the wrong axis leaves height unbounded.
        let result = clampedImageDimensions(width: 1000, height: 4000, maxDimension: 2000)
        XCTAssertEqual(result.height, 2000)
        XCTAssertEqual(result.width, 500)
    }

    func testClampedCaptureImageProducesExactPixelDimensions() throws {
        // Constructing the source with lockFocus is deliberate: it reproduces the
        // backing-scale-aware input the camera path sees on a Retina display.
        let source = NSImage(size: NSSize(width: 4000, height: 3000))
        source.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 4000, height: 3000))
        source.unlockFocus()

        let clamped = clampedImage(source, maxDimension: 2048)
        let rep = try XCTUnwrap(clamped.representations.first)

        // Pixel dimensions, not point dimensions: NSImage(size:) is in points, and a
        // backing-scale-aware rasterizer would silently emit 4096x3072 here on a Retina
        // display, defeating the bound entirely.
        XCTAssertEqual(rep.pixelsWide, 2048)
        XCTAssertEqual(rep.pixelsHigh, 1536)
    }

    /// On a Retina display an image's size in points is half its size in
    /// pixels. Encoding must keep the pixels.
    func testImageEncodingKeepsPixelDimensions() throws {
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 200,
                pixelsHigh: 100,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        rep.size = NSSize(width: 100, height: 50)
        let image = NSImage(size: NSSize(width: 100, height: 50))
        image.addRepresentation(rep)

        for data in [ImageFormat.png.encode(image), ImageFormat.jpeg.encode(image)] {
            let decoded = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(data)))
            XCTAssertEqual(decoded.pixelsWide, 200)
            XCTAssertEqual(decoded.pixelsHigh, 100)
        }
    }
}
