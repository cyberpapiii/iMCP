import AppKit
import SwiftUI

/// The app's shared design values. Later screens add their spacing, radii,
/// type and motion here as they are touched; nothing else defines them.
enum DesignTokens {
    /// What each status level looks like. Colour is never the only signal:
    /// every use sits beside words or an icon that say the same thing.
    enum StatusColor {
        static let ok = Color.green
        static let attention = Color.orange
        static let problem = Color.red
    }

    enum Spacing {
        static let hairline: CGFloat = 1
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        /// The gutter between a panel's edge and its text.
        static let lg: CGFloat = 14
        /// The margin inside a sheet.
        static let xl: CGFloat = 20
        /// The margin inside a window that stands alone.
        static let window: CGFloat = 24
    }

    enum Radius {
        static let row: CGFloat = 6
        /// A note laid over the map.
        static let callout: CGFloat = 8
        static let bar: CGFloat = 3
    }

    enum Opacity {
        /// Content that is being replaced: still readable, plainly not final.
        static let working: Double = 0.5
        /// A row under the pointer.
        static let hover: Double = 0.08
        /// The fill behind text to copy.
        static let well: Double = 0.12
    }

    enum Typography {
        /// Nothing the owner reads is set smaller than this.
        static let minimumSize: CGFloat = 12
        static let sectionHeader = Font.system(size: 13, weight: .semibold)
        static let menuHeaderTitle = Font.system(size: 14, weight: .semibold)
        static let detail = Font.system(size: minimumSize)
        /// Machine text only: fingerprints, paths, commands and snippets.
        static let code = Font.system(size: minimumSize, design: .monospaced)
        /// Text to copy into a client's configuration.
        static let snippet = Font.system(.body, design: .monospaced)
        /// A pairing code, read off the screen and typed somewhere else.
        static let pairingCode = Font.system(.title2, design: .monospaced)
        static let sheetTitle = Font.title3.weight(.semibold)
    }

    enum Size {
        /// Fixed, so the menu panel only ever changes height.
        static let menuPanelWidth: CGFloat = 298
        /// A service in the menu's grid: the round icon, its symbol's inset,
        /// and the badge on it when the service cannot reach its data.
        static let serviceTileIcon: CGFloat = 32
        static let serviceTileIconInset: CGFloat = 7
        static let serviceBadge: CGFloat = 13
        static let serviceColumns = 3
        /// The column a status icon sits in, so titles line up under each other.
        static let statusIcon: CGFloat = 14
        /// The app icon at the top of the menu, and the dot under its name.
        static let menuHeaderIcon: CGFloat = 36
        static let statusDot: CGFloat = 8
        /// Fixed, so the Location toolbar's buttons stay put as the date changes.
        static let locationDateWidth: CGFloat = 140
        /// The narrowest the map and the list beside it go. The map's part of
        /// the toolbar holds every control, so the map is as wide as they are
        /// with the longest one-day title ("Wednesday, September 30"), the
        /// Route and Heat switch, and the Day, Week, Month, All picker at
        /// their own widths.
        static let locationMapMinWidth: CGFloat = 880
        static let locationPanelMinWidth: CGFloat = 300
        /// A unified window toolbar's height on macOS 26.
        static let windowToolbarHeight: CGFloat = 52
        static let legendBarWidth: CGFloat = 90
        static let legendBarHeight: CGFloat = 6
        static let trackLineWidth: CGFloat = 3.5
        /// The dark edge on each side of the track.
        static let trackCasing: CGFloat = 1.5
        /// A named place's centre, and the device's position now.
        static let placeDot: CGFloat = 8
        static let latestFixDot: CGFloat = 16
        /// Fixed, so a sheet only ever changes height.
        static let sheetWidth: CGFloat = 460
        /// A list inside a sheet is as tall as its rows up to this, then scrolls.
        static let sheetListMaxHeight: CGFloat = 320
        /// Room for "400 m", so the slider beside it keeps its length.
        static let radiusValueWidth: CGFloat = 52
        /// Fixed, so the sidebar and every page keep their place.
        static let settingsWindowWidth: CGFloat = 760
        static let settingsWindowHeight: CGFloat = 580
        static let settingsSidebarWidth: CGFloat = 220
        static let settingsSidebarRow: CGFloat = 32
        /// The app icon at the top of the sidebar, and at the top of a page.
        static let settingsServerIcon: CGFloat = 30
        static let settingsHeroIcon: CGFloat = 44
        static let emptyStateIcon: CGFloat = 28
        static let permissionIcon: CGFloat = 22
        /// Fixed, so the sign-in and approval windows only ever change height.
        static let promptWidth: CGFloat = 420
        static let promptIcon: CGFloat = 64
        static let connectWindowWidth: CGFloat = 520
        static let connectWindowHeight: CGFloat = 560
        /// The room a small spinner takes inside a button.
        static let spinner: CGFloat = 16
    }

    /// What the menu panel is drawn on: thin over Liquid Glass, thick before it.
    static var panelMaterial: Material {
        if #available(macOS 26.0, *) {
            return .thinMaterial
        } else {
            return .thick
        }
    }

    /// How long a passing notice stays before it clears itself.
    enum Linger {
        /// "Copied", before the button offers to copy again.
        static let confirmation: Duration = .seconds(2)
        /// The last word of a prompt that answered itself, before it closes.
        static let closingNotice: Duration = .seconds(3)
        /// A sheet that has saved, between its tick and its closing.
        static let ceremony: Duration = .milliseconds(350)
        /// "Paired", before the approval window closes.
        static let pairedNotice: Duration = .milliseconds(1200)
    }

    /// How long a change takes. Neither bounces.
    enum Motion {
        /// A small thing changing under the pointer.
        case quick
        /// A section folding, or a row joining or leaving a list.
        case surface
        /// A rare success being marked: a client pairs, a place is saved.
        case ceremony

        var duration: TimeInterval {
            switch self {
            case .quick: return 0.16
            case .surface: return 0.28
            case .ceremony: return 0.3
            }
        }

        var exitDuration: TimeInterval { duration * 2 / 3 }

        /// Under Reduce Motion the change still happens, as a short fade.
        func animation(reduceMotion: Bool) -> Animation {
            reduceMotion
                ? .easeOut(duration: Motion.quick.duration)
                : .snappy(duration: duration, extraBounce: 0)
        }

        /// For a change that is only movement, such as a window growing: under
        /// Reduce Motion it happens at once.
        func movement(reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : animation(reduceMotion: false)
        }

        /// How far an arriving view travels.
        static let revealDistance: CGFloat = 6
    }
}

/// iMCP's state in a dot and a word. The menu's header and the top of
/// Settings both show it, so they always agree.
struct ServerStateBadge: Equatable {
    var word: String
    var color: Color

    init(isServerEnabled: Bool, level: StatusSummary.Level) {
        guard isServerEnabled else {
            word = "Off"
            color = Color.secondary.opacity(0.6)
            return
        }
        switch level {
        case .ok: word = "Running"
        case .attention, .problem: word = "Needs attention"
        }
        color = level.color
    }
}

extension StatusSummary.Level {
    var color: Color {
        switch self {
        case .ok: return DesignTokens.StatusColor.ok
        case .attention: return DesignTokens.StatusColor.attention
        case .problem: return DesignTokens.StatusColor.problem
        }
    }

    /// A different outline per level, so the level reads without colour.
    var symbolName: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.octagon.fill"
        }
    }
}

extension View {
    /// The one way a view animates: a change of `value` moves what depends on
    /// it, unless Reduce Motion is on.
    func motion<Value: Equatable>(_ motion: DesignTokens.Motion, value: Value) -> some View {
        modifier(MotionModifier(motion: motion, value: value))
    }
}

extension View {
    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// The one button on a surface that does what the surface is for.
    @ViewBuilder
    func glassProminentButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func glassFill(tint: Color, in shape: some Shape) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint).interactive(), in: shape)
        } else {
            self.background(shape.fill(tint))
        }
    }
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    let motion: DesignTokens.Motion
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(motion.animation(reduceMotion: reduceMotion), value: value)
    }
}

/// Takes the height its content needs, and moves to a new one instead of
/// jumping. The first height is taken as it is, so a window opens at its size.
struct FittedHeight<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var height: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { measured in
                let opening = height == nil
                withAnimation(opening ? nil : DesignTokens.Motion.surface.movement(reduceMotion: reduceMotion)) {
                    height = measured
                }
            }
            .modifier(AnimatedHeight(height: height))
            .clipped()
    }
}

/// Sets a height, and passes through every height on the way to a new one.
/// A plain animated frame would not: a window follows the layout, and the
/// layout jumps straight to the end of an animation.
struct AnimatedHeight: ViewModifier, Animatable {
    var height: CGFloat?

    var animatableData: CGFloat {
        get { height ?? 0 }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        content.frame(height: height, alignment: .top)
    }
}

/// A label that can say several things without changing size, so the button
/// it is in never moves its neighbours. Every face takes up room; only the
/// current one shows.
struct SteadyLabel: View {
    struct Face: Hashable {
        var text: String
        /// Shows a spinner before the words.
        var working = false
    }

    let faces: [Face]
    let current: Face

    var body: some View {
        ZStack {
            ForEach(faces, id: \.self) { face in
                HStack(spacing: DesignTokens.Spacing.sm) {
                    if face.working {
                        spinner(running: face == current)
                    }
                    Text(face.text)
                }
                .opacity(face == current ? 1 : 0)
                .accessibilityHidden(face != current)
            }
        }
        .motion(.quick, value: current)
    }

    /// A spinner that is not on show is not there to spin.
    @ViewBuilder
    private func spinner(running: Bool) -> some View {
        if running {
            ProgressView()
                .controlSize(.small)
                .frame(width: DesignTokens.Size.spinner, height: DesignTokens.Size.spinner)
        } else {
            Color.clear
                .frame(width: DesignTokens.Size.spinner, height: DesignTokens.Size.spinner)
        }
    }
}

/// The mark of a rare success. It draws itself once when `isDrawn` turns
/// true and is simply there if it starts out true, so nothing replays on a
/// view that comes back. It takes the colour of the text around it. It is
/// decoration: `announcement` says the same thing to assistive technology.
struct SuccessTick: View {
    let isDrawn: Bool
    let announcement: String
    var size = DesignTokens.Size.statusIcon

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TickShape()
            .trim(from: 0, to: isDrawn || reduceMotion ? 1 : 0)
            .stroke(style: StrokeStyle(lineWidth: size / 7, lineCap: .round, lineJoin: .round))
            .opacity(isDrawn ? 1 : 0)
            .frame(width: size, height: size)
            .motion(.ceremony, value: isDrawn)
            .accessibilityHidden(true)
            .onChange(of: isDrawn) { _, drawn in
                if drawn { AccessibilityNotification.Announcement(announcement).post() }
            }
    }

    private struct TickShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.54))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.41, y: rect.minY + rect.height * 0.76))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.82, y: rect.minY + rect.height * 0.26))
            return path
        }
    }
}

/// A button's words, which give way to the tick once what they asked for is
/// done. The button keeps its size.
struct DoneLabel: View {
    let title: String
    let isDone: Bool
    let announcement: String

    var body: some View {
        Text(title)
            .opacity(isDone ? 0 : 1)
            .accessibilityHidden(isDone)
            .overlay { SuccessTick(isDrawn: isDone, announcement: announcement) }
            .motion(.quick, value: isDone)
            .accessibilityLabel(isDone ? announcement : title)
    }
}

/// One quiet line saying something needs the owner: the icon's shape and
/// colour give the level, the words say what.
struct StatusNote: View {
    let level: StatusSummary.Level
    let text: String

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: level.symbolName)
                .foregroundStyle(level.color)
        }
        .font(DesignTokens.Typography.detail)
    }
}

extension AnyTransition {
    /// How a view joins or leaves its container: it fades, and slides a few
    /// points down into place unless Reduce Motion is on. Pair it with
    /// `motion(_:value:)` on the container.
    static func reveal(_ motion: DesignTokens.Motion = .surface) -> AnyTransition {
        .asymmetric(
            insertion: AnyTransition(RevealTransition()),
            removal: AnyTransition(RevealTransition()).animation(.easeOut(duration: motion.exitDuration))
        )
    }
}

private struct RevealTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content.modifier(RevealEffect(isShown: phase.isIdentity))
    }
}

private struct RevealEffect: ViewModifier {
    let isShown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown || reduceMotion ? 0 : -DesignTokens.Motion.revealDistance)
    }
}

/// The grey line under a control that says what it does.
/// The app's icon at a given size, drawn by AppKit at that size. Stretching
/// the image with `resizable()` scales a single bitmap, which comes out
/// soft or pixelated; this draws the icon fresh for the size and the
/// screen's scale. Decoration: the name beside it says what it is.
struct AppIconImage: View {
    let size: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Image(nsImage: Self.image(size: size, scale: displayScale))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// One drawing per size and scale: the body runs on every state change.
    @MainActor private static var drawn: [CGSize: NSImage] = [:]

    @MainActor private static func image(size: CGFloat, scale: CGFloat) -> NSImage {
        let key = CGSize(width: size, height: scale)
        if let image = drawn[key] { return image }
        let image = render(size: size, scale: scale)
        drawn[key] = image
        return image
    }

    private static func render(size: CGFloat, scale: CGFloat) -> NSImage {
        let icon = NSApplication.shared.applicationIconImage ?? NSImage()
        let pixels = NSSize(width: size * scale, height: size * scale)
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(pixels.width),
                pixelsHigh: Int(pixels.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else { return icon }
        bitmap.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
        context?.imageInterpolation = .high
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return image
    }
}

/// A Settings row that opens a page in the browser, marked as leaving the app.
struct ExternalLinkRow: View {
    let title: String
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(DesignTokens.Typography.detail.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SettingsCaption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(DesignTokens.Typography.detail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
