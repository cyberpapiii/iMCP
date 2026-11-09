import MapKit
import SwiftUI

struct LocationMapView: View, Equatable {
    /// Not observed: the values below are what this view draws.
    let model: LocationWindowModel
    let scene: LocationWindowModel.MapScene?
    let latest: LocationWindowModel.LatestFix?
    let latestTitle: String?
    let selectedItemID: String?

    @State private var position: MapCameraPosition = .automatic
    @AppStorage(PreferenceKey.locationMapMode) private var mode = MapMode.route
    /// Where the map is looking, so the heat layers redraw as it moves.
    @State private var camera: MapCamera?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (lhs: LocationMapView, rhs: LocationMapView) -> Bool {
        lhs.scene == rhs.scene && lhs.latest == rhs.latest && lhs.latestTitle == rhs.latestTitle
            && lhs.selectedItemID == rhs.selectedItemID
    }

    var body: some View {
        ZStack {
            // Holds the map's place until there is something to draw on it.
            Rectangle()
                .fill(.quaternary)
            map
                .opacity(scene == nil ? 0 : 1)
        }
        // The map runs up under the window's glass toolbar; the legend and
        // the notes over it stay below the toolbar.
        .ignoresSafeArea(.container, edges: .top)
        .motion(.surface, value: scene == nil)
        .overlay(alignment: .topTrailing) {
            ZStack {
                if let span = scene?.trackSpan {
                    if mode == .heat {
                        HeatLegend()
                            .transition(.opacity)
                    } else {
                        TrackRampLegend(span: span)
                            .transition(.opacity)
                    }
                }
            }
            .padding(DesignTokens.Spacing.lg)
            .motion(.surface, value: scene?.trackSpan)
            .motion(.quick, value: mode)
        }
        .overlay(alignment: .topLeading) {
            ZStack {
                if scene?.hasPositions == false {
                    Text("No positions recorded in this period.")
                        .font(.callout)
                        .padding(DesignTokens.Spacing.md)
                        .mapCallout(in: RoundedRectangle(cornerRadius: DesignTokens.Radius.callout))
                        .transition(.opacity)
                }
            }
            .padding(DesignTokens.Spacing.lg)
            .motion(.surface, value: scene?.hasPositions)
        }
    }

    private var map: some View {
        MapReader { proxy in
            baseMap
                .overlay {
                    if mode == .heat, let scene {
                        HeatLayer(proxy: proxy, points: scene.heatPoints, paths: scene.heatPaths, camera: camera)
                            .transition(.opacity)
                    }
                }
                .motion(.surface, value: mode)
        }
    }

    private var baseMap: some View {
        Map(
            position: $position,
            selection: Binding(get: { model.selectedItemID }, set: { model.selectedItemID = $0 })
        ) {
            if let scene {
                // The heat map draws its own layers over the map; see HeatLayer.
                if mode == .route {
                    // A dark casing under the whole track first, so the colour
                    // reads over any street, light or dark.
                    ForEach(scene.colourRuns.indices, id: \.self) { index in
                        MapPolyline(coordinates: scene.colourRuns[index].points)
                            .stroke(
                                .black.opacity(0.45),
                                style: StrokeStyle(
                                    lineWidth: DesignTokens.Size.trackLineWidth + DesignTokens.Size.trackCasing * 2,
                                    lineCap: .round,
                                    lineJoin: .round
                                )
                            )
                    }
                    ForEach(scene.colourRuns.indices, id: \.self) { index in
                        MapPolyline(coordinates: scene.colourRuns[index].points)
                            .stroke(
                                TrackRamp.colour(at: scene.colourRuns[index].progress),
                                style: StrokeStyle(
                                    lineWidth: DesignTokens.Size.trackLineWidth,
                                    lineCap: .round,
                                    lineJoin: .round
                                )
                            )
                    }
                    // A hole in the record is a dotted line. Its words are in the
                    // list; the map shows them only for the gap picked there.
                    // A flown gap is drawn as its flight; it is dotted only
                    // while picked in the list.
                    ForEach(scene.gapSpans.filter { !$0.isFlight || $0.id == selectedItemID }) { span in
                        let isSelected = selectedItemID == span.id
                        MapPolyline(coordinates: [span.from, span.to], contourStyle: .geodesic)
                            .stroke(
                                isSelected ? Color.primary : Color.gray,
                                style: StrokeStyle(lineWidth: isSelected ? 3 : 2, lineCap: .round, dash: [1, 7])
                            )
                        if isSelected {
                            Annotation("", coordinate: midpoint(span.from, span.to), anchor: .center) {
                                Text("No data for \(LocationTimelineItems.duration(span.gap.duration))")
                                    .font(DesignTokens.Typography.detail)
                                    .padding(.horizontal, DesignTokens.Spacing.sm)
                                    .padding(.vertical, DesignTokens.Spacing.xxs)
                                    .mapCallout(in: Capsule())
                            }
                            .tag(span.id)
                        }
                    }
                }
                // Steps taken by air: a dashed arc, with a plane on it facing
                // the way it flew.
                ForEach(scene.flights.indices, id: \.self) { index in
                    let arc = scene.flights[index].points
                    MapPolyline(coordinates: arc)
                        .stroke(
                            Color.primary.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [6, 5])
                        )
                    // The plane only on a real crossing, not on the climb
                    // out of the airport before the phone went quiet.
                    if arc.count > 2, MKMapPoint(arc[0]).distance(to: MKMapPoint(arc[arc.count - 1])) > 50_000 {
                        let middle = arc.count / 2
                        Annotation("", coordinate: arc[middle], anchor: .center) {
                            FlightMark(from: arc[middle - 1], to: arc[middle + 1])
                        }
                    }
                }
                ForEach(scene.places, id: \.id) { place in
                    let centre = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
                    let colour = LocationTimelineItems.StopKind.place.colour
                    MapCircle(center: centre, radius: place.radiusMeters)
                        .foregroundStyle(colour.opacity(0.10))
                        .stroke(colour.opacity(0.6), lineWidth: 1.5)
                    // The place is its circle, and its name and dot while
                    // nothing stopped there in this period. A stop there is
                    // drawn with the same name, and two marks a few metres
                    // apart read as a mistake.
                    if !scene.stops.contains(where: { $0.title == place.name }) {
                        Annotation(place.name, coordinate: centre, anchor: .center) {
                            Circle()
                                .fill(colour)
                                .frame(width: DesignTokens.Size.placeDot, height: DesignTokens.Size.placeDot)
                                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        }
                        .annotationTitles(.visible)
                        .tag("place-\(place.id)")
                    }
                }
                // The heat map keeps only the places with names; every
                // unnamed stop is part of the glow.
                ForEach(mode == .heat ? scene.stops.filter { $0.kind != .unnamed } : scene.stops) { stop in
                    Annotation(
                        stop.title,
                        coordinate: CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)
                    ) {
                        StopPinView(
                            diameter: stop.diameter,
                            kind: stop.kind,
                            isSelected: selectedItemID.map(stop.ids.contains) ?? false
                        )
                        .onTapGesture { model.selectedItemID = stop.id }
                    }
                    .tag(stop.id)
                }
            }
            if let latest, let latestTitle {
                if let accuracy = latest.accuracyMeters {
                    MapCircle(center: latest.coordinate, radius: accuracy)
                        .foregroundStyle(DesignTokens.StatusColor.ok.opacity(0.15))
                        .stroke(DesignTokens.StatusColor.ok, lineWidth: 1)
                }
                Annotation(latestTitle, coordinate: latest.coordinate) {
                    LatestFixPuck()
                }
                .tag("latest")
            }
        }
        // Muted, without points of interest: the base map is the setting,
        // the track and the stops are what it is about.
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapZoomStepper()
        }
        .onMapCameraChange(frequency: .continuous) { context in camera = context.camera }
        // A new period opens on all of it: MapKit's own framing left out
        // the far end of a flight.
        .onChange(of: scene?.range) { _, _ in
            guard let bounds = scene?.bounds else {
                position = .automatic
                return
            }
            let margin = max(bounds.width, bounds.height) * 0.12 + 2_000
            position = .rect(bounds.insetBy(dx: -margin, dy: -margin))
        }
        .onChange(of: selectedItemID) { _, id in
            guard let id, let region = region(for: id) else { return }
            withAnimation(reduceMotion ? nil : DesignTokens.Motion.surface.animation(reduceMotion: false)) {
                position = .region(region)
            }
        }
    }

    /// Where the camera goes for a stop or a gap picked in the list: around
    /// the stop, or around both ends of the gap.
    private func region(for id: String) -> MKCoordinateRegion? {
        if let stop = scene?.stops.first(where: { $0.ids.contains(id) }) {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude),
                latitudinalMeters: 800,
                longitudinalMeters: 800
            )
        }
        guard let span = scene?.gapSpans.first(where: { $0.id == id }) else { return nil }
        let a = MKMapPoint(span.from)
        let b = MKMapPoint(span.to)
        let rect = MKMapRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
        let padded = rect.insetBy(dx: -max(rect.width * 0.4, 600), dy: -max(rect.height * 0.4, 600))
        return MKCoordinateRegion(padded)
    }

    private func midpoint(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2, longitude: (a.longitude + b.longitude) / 2)
    }
}

extension LocationTimelineItems.StopKind {
    /// Paired with `symbolName` wherever it is used, never alone.
    var colour: Color {
        switch self {
        case .place: return .blue
        case .label: return .gray
        case .unnamed: return .orange
        }
    }
}

/// A stop on the map. A named stop is a solid disc; an unnamed one is a ring
/// with a pale centre, so the two differ in shape as well as colour.
private struct StopPinView: View {
    let diameter: CGFloat
    let kind: LocationTimelineItems.StopKind
    let isSelected: Bool

    var body: some View {
        let outline = isSelected ? Color.primary : Color.white
        ZStack {
            Circle()
                .fill(kind.colour.opacity(0.85))
            if kind == .unnamed {
                Circle()
                    .fill(.white.opacity(0.9))
                    .padding(diameter * 0.26)
            }
        }
        .overlay(Circle().stroke(outline, lineWidth: isSelected ? 3 : 2))
        .frame(width: diameter, height: diameter)
        .scaleEffect(isSelected ? 1.2 : 1)
        .shadow(color: .black.opacity(0.35), radius: isSelected ? 4 : 2)
        .motion(.quick, value: isSelected)
    }
}

/// Where the device is now: a dot in the status green with a white rim, and
/// a soft ring that breathes out from it. Under Reduce Motion the ring stays
/// still.
private struct LatestFixPuck: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing = false

    var body: some View {
        let size = DesignTokens.Size.latestFixDot
        ZStack {
            Circle()
                .fill(DesignTokens.StatusColor.ok.opacity(0.3))
                .frame(width: size * 2.2, height: size * 2.2)
                .scaleEffect(isBreathing ? 1 : 0.6)
                .opacity(isBreathing ? 0 : 1)
            Circle()
                .fill(DesignTokens.StatusColor.ok)
                .frame(width: size, height: size)
                .overlay(Circle().stroke(.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.35), radius: 3)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) {
                isBreathing = true
            }
        }
        .accessibilityHidden(true)
    }
}

private extension View {
    /// The glass every note over the map sits on, matching the toolbar.
    @ViewBuilder
    func mapCallout(in shape: some Shape) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.thinMaterial, in: shape)
        }
    }
}

/// The colour of the track by time: cool at the first fix, warm at the last,
/// so the eye reads direction without arrows. One ramp shared by the line
/// and its legend so they cannot disagree.
enum TrackRamp {
    private static let stops: [(r: Double, g: Double, b: Double)] = [
        (0.20, 0.45, 0.95),  // blue: start
        (0.25, 0.70, 0.85),  // teal
        (0.60, 0.80, 0.45),  // green-yellow
        (0.98, 0.70, 0.25),  // amber
        (0.95, 0.35, 0.30),  // coral: end
    ]

    static func colour(at progress: Double) -> Color {
        let clamped = min(1, max(0, progress))
        let scaled = clamped * Double(stops.count - 1)
        let index = min(stops.count - 2, Int(scaled))
        let mix = scaled - Double(index)
        let a = stops[index]
        let b = stops[index + 1]
        return Color(
            red: a.r + (b.r - a.r) * mix,
            green: a.g + (b.g - a.g) * mix,
            blue: a.b + (b.b - a.b) * mix
        )
    }

    static let gradient = LinearGradient(
        colors: stride(from: 0.0, through: 1.0, by: 0.05).map(colour(at:)),
        startPoint: .leading,
        endPoint: .trailing
    )
}

/// A plane on a flight's arc, turned to the way it was flying.
private struct FlightMark: View {
    let from: CLLocationCoordinate2D
    let to: CLLocationCoordinate2D

    var body: some View {
        let a = MKMapPoint(from)
        let b = MKMapPoint(to)
        Image(systemName: "airplane")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary)
            .rotationEffect(.radians(atan2(b.y - a.y, b.x - a.x)))
            .padding(DesignTokens.Spacing.xs)
            .mapCallout(in: Circle())
            .accessibilityLabel("Flight")
    }
}

/// The Location map's two ways of drawing the track.
enum MapMode: String {
    case route
    case heat
}

/// The density field as an image: each spot adds a soft bump to a coarse
/// grid, and the grid's values are coloured from blue to red. Computed on the
/// CPU each frame the map moves; a week is a few thousand spots on a grid of
/// a few tens of thousands of cells, well under a frame.
enum HeatField {
    /// Grid cell size in points; the image is drawn smooth over it.
    static let cell: CGFloat = 4
    /// Each spot's reach, in cells.
    static let reach = 6
    /// The density that reads as red. Values are taken on a log scale, so a
    /// week at home is red without every corner shop being red too.
    static let saturation = 40.0
    static let maximumOpacity = 0.62

    private static let ramp: [(Double, Double, Double)] = [
        (0.15, 0.30, 0.95),
        (0.10, 0.75, 0.90),
        (0.30, 0.85, 0.35),
        (1.00, 0.85, 0.20),
        (0.95, 0.20, 0.15),
    ]

    /// Colours for the legend, the same as the field's.
    static let rampColours = ramp.map { Color(red: $0.0, green: $0.1, blue: $0.2) }

    /// A round bump that falls smoothly to nothing at `reach`, so piled-up
    /// spots never show the square grid they are added on.
    private static let kernel: [Double] = {
        let radius = Double(reach) + 0.5
        var values: [Double] = []
        for dy in -reach ... reach {
            for dx in -reach ... reach {
                let falloff = max(0, 1 - Double(dx * dx + dy * dy) / (radius * radius))
                values.append(falloff * falloff)
            }
        }
        return values
    }()

    static func image(spots: [(CGPoint, Double)], size: CGSize) -> CGImage? {
        let width = Int((size.width / cell).rounded(.up))
        let height = Int((size.height / cell).rounded(.up))
        guard width > 0, height > 0, !spots.isEmpty else { return nil }
        var density = [Double](repeating: 0, count: width * height)
        let span = reach * 2 + 1
        for (at, weight) in spots {
            let cx = Int(at.x / cell)
            let cy = Int(at.y / cell)
            guard cx > -reach, cy > -reach, cx < width + reach, cy < height + reach else { continue }
            for dy in -reach ... reach {
                let y = cy + dy
                guard y >= 0, y < height else { continue }
                for dx in -reach ... reach {
                    let x = cx + dx
                    guard x >= 0, x < width else { continue }
                    density[y * width + x] += weight * kernel[(dy + reach) * span + dx + reach]
                }
            }
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0 ..< density.count where density[index] > 0.05 {
            let value = min(1, log1p(density[index]) / log1p(saturation))
            let scaled = value * Double(ramp.count - 1)
            let lower = min(ramp.count - 2, Int(scaled))
            let mix = scaled - Double(lower)
            let a = ramp[lower]
            let b = ramp[lower + 1]
            let alpha = maximumOpacity * min(1, density[index] / 0.6)
            pixels[index * 4] = UInt8((a.0 + (b.0 - a.0) * mix) * alpha * 255)
            pixels[index * 4 + 1] = UInt8((a.1 + (b.1 - a.1) * mix) * alpha * 255)
            pixels[index * 4 + 2] = UInt8((a.2 + (b.2 - a.2) * mix) * alpha * 255)
            pixels[index * 4 + 3] = UInt8(alpha * 255)
        }
        guard
            let provider = CGDataProvider(data: Data(pixels) as CFData),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else { return nil }
        return image
    }
}

/// The heat map, drawn over the map in two layers as Strava draws one.
/// Underneath, a blurred field of where time was spent, coloured from blue
/// (passed through) to red (lived there). On top, every journey as a thin
/// pink line; lines add up where they overlap, so a street travelled often
/// burns towards white. MapKit's own lines cannot add up, so both layers
/// are drawn here, converted through the map's proxy as it moves.
private struct HeatLayer: View {
    let proxy: MapProxy
    let points: [LocationTimelineItems.HeatPoint]
    let paths: [LocationTimelineItems.Segment]
    /// Not read: a new camera is what makes the layers redraw.
    let camera: MapCamera?

    /// From the flat map to the view. A flat map, turned or not, is an affine
    /// picture of MapKit's projection, so three corners of the view, asked
    /// of the map once, place every point; asking the map for each of
    /// thousands of points every frame of a pan stutters.
    private func projection(size: CGSize) -> ((MKMapPoint) -> CGPoint)? {
        guard
            let origin = proxy.convert(CGPoint.zero, from: .local),
            let right = proxy.convert(CGPoint(x: size.width, y: 0), from: .local),
            let down = proxy.convert(CGPoint(x: 0, y: size.height), from: .local)
        else { return nil }
        let o = MKMapPoint(origin)
        let r = MKMapPoint(right)
        let d = MKMapPoint(down)
        // The map points of the view's x and y axes; solve for the inverse.
        let ax = r.x - o.x, ay = r.y - o.y
        let bx = d.x - o.x, by = d.y - o.y
        let determinant = ax * by - ay * bx
        guard abs(determinant) > 0 else { return nil }
        return { point in
            let px = point.x - o.x, py = point.y - o.y
            let u = (px * by - py * bx) / determinant
            let v = (ax * py - ay * px) / determinant
            return CGPoint(x: u * size.width, y: v * size.height)
        }
    }

    var body: some View {
        ZStack {
            Canvas { context, size in
                guard let project = projection(size: size) else { return }
                let spots = points.map { point in
                    (
                        project(
                            MKMapPoint(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
                        ), point.weight
                    )
                }
                guard let field = HeatField.image(spots: spots, size: size) else { return }
                context.draw(Image(decorative: field, scale: 1), in: CGRect(origin: .zero, size: size))
            }

            Canvas { context, size in
                guard let project = projection(size: size) else { return }
                context.blendMode = .plusLighter
                let lines = paths.map { path in
                    var line = Path()
                    for (index, coordinate) in path.points.enumerated() {
                        let at = project(MKMapPoint(coordinate))
                        if index == 0 { line.move(to: at) } else { line.addLine(to: at) }
                    }
                    return line
                }
                // A soft glow under every line first, so lines a few metres
                // apart, the same street on another day, pool into one
                // brighter band instead of standing side by side.
                for line in lines {
                    context.stroke(line, with: .color(HeatMap.glow), style: HeatMap.glowStyle)
                }
                // Each pass adds light to the last, so a street travelled
                // once is a faint thread and one travelled every day burns
                // towards white.
                for line in lines {
                    context.stroke(line, with: .color(HeatMap.line), style: HeatMap.lineStyle)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The heat map's values, tuned by eye on a week of ten-minute samples.
enum HeatMap {
    static let line = Color(red: 0.95, green: 0.25, blue: 0.55).opacity(0.45)
    static let lineStyle = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
    static let glow = Color(red: 0.95, green: 0.3, blue: 0.5).opacity(0.12)
    static let glowStyle = StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)
}

private struct HeatLegend: View {
    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text("Passing")
            RoundedRectangle(cornerRadius: DesignTokens.Radius.bar)
                .fill(LinearGradient(colors: HeatField.rampColours, startPoint: .leading, endPoint: .trailing))
                .frame(width: DesignTokens.Size.legendBarWidth, height: DesignTokens.Size.legendBarHeight)
                .accessibilityHidden(true)
            Text("Most time")
        }
        .font(DesignTokens.Typography.detail)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .mapCallout(in: Capsule())
        .help("Colour shows where the most time was spent; the pink lines are journeys, brighter where repeated")
        .accessibilityElement(children: .combine)
    }
}

private struct TrackRampLegend: View {
    let span: ClosedRange<Date>

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(label(span.lowerBound))
            RoundedRectangle(cornerRadius: DesignTokens.Radius.bar)
                .fill(TrackRamp.gradient)
                .frame(width: DesignTokens.Size.legendBarWidth, height: DesignTokens.Size.legendBarHeight)
                .accessibilityHidden(true)
            Text(label(span.upperBound))
        }
        .font(DesignTokens.Typography.detail)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .mapCallout(in: Capsule())
        .help("Track colour runs from the earliest recorded position to the latest")
        .accessibilityElement(children: .combine)
    }

    private func label(_ date: Date) -> String {
        if Calendar.current.isDate(span.lowerBound, inSameDayAs: span.upperBound) {
            return LocationTimelineItems.clock(date)
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
