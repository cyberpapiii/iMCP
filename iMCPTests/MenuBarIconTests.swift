import AppKit
import XCTest

@testable import iMCP

final class MenuBarIconTests: XCTestCase {
    /// The dot is drawn, not an asset, so the pixels are what is checked: the
    /// attention image differs from its own face drawn without the dot only in
    /// its top trailing corner, where a clear ring surrounds a solid dot.
    @MainActor
    func testAttentionIconAddsADotInTheCornerAndNothingElse() throws {
        func alpha(_ image: NSImage) throws -> (Int, Int) -> CGFloat {
            let rep = try XCTUnwrap(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: 32,
                    pixelsHigh: 32,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                )
            )
            rep.size = image.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
            // Bitmap rows run top to bottom; points run bottom to top at 2x.
            return { x, y in rep.colorAt(x: x, y: 31 - y)?.alphaComponent ?? -1 }
        }

        XCTAssertTrue(MenuBarIcon.on.isTemplate)
        XCTAssertTrue(MenuBarIcon.attention.isTemplate)
        XCTAssertEqual(MenuBarIcon.attention.size, MenuBarIcon.on.size)

        let plain = try alpha(MenuBarIcon.image(from: NSImage(named: "MenuIcon-Attention"), attention: false))
        let dotted = try alpha(MenuBarIcon.attention)

        // Dot centre is (12.5, 12.5) pt, so pixel (25, 25) at 2x.
        XCTAssertEqual(dotted(25, 25), 1, accuracy: 0.01)
        XCTAssertEqual(dotted(25, 16), 0, accuracy: 0.01, "clear ring below the dot")
        XCTAssertEqual(dotted(16, 25), 0, accuracy: 0.01, "clear ring beside the dot")
        // (17, 22) is the body's top edge, inside the ring.
        XCTAssertEqual(plain(17, 22), 1, accuracy: 0.01, "the plain icon is solid where the ring is cut")
        XCTAssertEqual(dotted(17, 22), 0, accuracy: 0.01, "and the ring cuts it")

        var changedOutsideTheCorner = 0
        var solidInThePlainIcon = 0
        for y in 0 ..< 32 {
            for x in 0 ..< 32 {
                if plain(x, y) > 0.5 { solidInThePlainIcon += 1 }
                let dx = Double(x) + 0.5 - 25
                let dy = Double(y) + 0.5 - 25
                if (dx * dx + dy * dy).squareRoot() > 11, abs(plain(x, y) - dotted(x, y)) > 0.01 {
                    changedOutsideTheCorner += 1
                }
            }
        }
        XCTAssertEqual(changedOutsideTheCorner, 0)
        XCTAssertGreaterThan(solidInThePlainIcon, 300, "the asset was found and drawn")
    }
}
