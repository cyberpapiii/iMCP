import AppKit
import SwiftUI

/// The menu-bar picture for a running server. Drawn at runtime from the
/// template assets so the attention dot is part of one template image: macOS
/// tints the whole thing for a light or dark menu bar, and a SwiftUI overlay
/// on a `MenuBarExtra` label is not reliably drawn.
enum MenuBarIcon {
    /// The dot sits in the top trailing corner. The clear ring around it is
    /// what makes it read as a dot on a glyph that fills its whole square.
    static let dotCenter = CGPoint(x: 12.5, y: 12.5)
    static let dotRadius: CGFloat = 3.5
    static let gapRadius: CGFloat = 5

    @MainActor static let on = image(from: NSImage(named: "MenuIcon-On"), attention: false)
    /// Needs you has its own face (eyes wide), with the dot added here.
    @MainActor static let attention = image(from: NSImage(named: "MenuIcon-Attention"), attention: true)

    static func image(from base: NSImage?, attention: Bool) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            base?.draw(in: rect)
            guard attention, let context = NSGraphicsContext.current?.cgContext else { return true }
            context.setBlendMode(.clear)
            context.fillEllipse(in: circle(radius: gapRadius))
            context.setBlendMode(.normal)
            context.setFillColor(.black)
            context.fillEllipse(in: circle(radius: dotRadius))
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func circle(radius: CGFloat) -> CGRect {
        CGRect(x: dotCenter.x - radius, y: dotCenter.y - radius, width: radius * 2, height: radius * 2)
    }
}

/// The menu-bar item's label. It observes the switch and the status itself
/// so the `App` scene reads nothing and is not rebuilt when they change.
struct MenuBarLabel: View {
    @ObservedObject var serverController: ServerController
    @ObservedObject var appStatus: AppStatusModel

    var body: some View {
        let indicator = MenuBarIndicator(
            serverEnabled: serverController.isServerEnabled,
            overall: appStatus.status.overall
        )
        image(for: indicator.icon)
            .accessibilityLabel(indicator.accessibilityDescription)
    }

    private func image(for icon: MenuBarIndicator.Icon) -> Image {
        switch icon {
        case .off: return Image("MenuIcon-Off")
        case .on: return Image(nsImage: MenuBarIcon.on)
        case .attention: return Image(nsImage: MenuBarIcon.attention)
        }
    }
}
