import AppKit
import SwiftUI

@MainActor
final class LocationWindowController: NSWindowController, NSWindowDelegate {
    private let model: LocationWindowModel

    init(model: LocationWindowModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // The view's toolbar becomes the window's, so the day controls sit in
        // the title bar as they do in Settings, and the map runs under it.
        let host = NSHostingController(rootView: LocationWindowView(model: model))
        host.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = host
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 1240, height: 760))
        window.center()
        window.title = "Location"
        window.minSize = NSSize(
            width: DesignTokens.Size.locationMapMinWidth + DesignTokens.Size.locationPanelMinWidth,
            height: 480
        )
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        model.startRefreshing()
    }

    func windowWillClose(_ notification: Notification) {
        model.stopRefreshing()
    }
}

private struct LocationWindowView: View {
    @AppStorage(PreferenceKey.locationMapMode) private var mapMode = MapMode.route
    @ObservedObject var model: LocationWindowModel

    var body: some View {
        // The model publishes for many reasons. Each part below is handed only
        // the values it draws and compares them, so a health tick or an
        // arriving address does not redraw the map.
        LocationMapView(
            model: model,
            scene: model.scene,
            latest: model.latest,
            latestTitle: model.latest.map { "\($0.deviceName) · \(RelativeAge.text(since: $0.at))" },
            selectedItemID: model.selectedItemID
        )
        .equatable()
        .frame(minWidth: DesignTokens.Size.locationMapMinWidth)
        .inspector(isPresented: .constant(true)) {
            VStack(spacing: 0) {
                LocationSidebar(
                    model: model,
                    summary: model.timeline.map(LocationTimelineItems.summaryText),
                    range: model.timeline?.range,
                    items: model.items,
                    lookups: model.lookups,
                    isLoading: model.isLoading
                )
                .equatable()
                Divider()
                HealthStrip(health: model.health, error: model.loadError)
                    .equatable()
            }
            // The device's name and summary sit up in the toolbar's band, which
            // has nothing of its own over the panel.
            .ignoresSafeArea(.container, edges: .top)
            .toolbar { panelToolbar }
            .inspectorColumnWidth(min: DesignTokens.Size.locationPanelMinWidth, ideal: 340, max: 460)
        }
        .navigationTitle("Location")
        .toolbar { toolbar }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar(removing: .title)
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .naming(let visit): NamePlaceSheet(model: model, visit: visit)
            case .adding: AddPlaceSheet(model: model)
            case .listing: PlacesListSheet(model: model)
            }
        }
    }

    /// The day as the window's title, with the arrows that step through days
    /// beside it in one capsule, as Settings steps through pages.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ControlGroup {
                Button("Previous \(model.period.name)", systemImage: "chevron.left") { model.step(by: -1) }
                    .disabled(!model.canStep)
                    .keyboardShortcut("[", modifiers: .command)
                Button("Next \(model.period.name)", systemImage: "chevron.right") { model.step(by: 1) }
                    .disabled(!model.canStep || model.isToday)
                    .keyboardShortcut("]", modifiers: .command)
            }
            .controlGroupStyle(.navigation)
        }
        // On its own glass, unlike Settings' title: here the map runs under
        // the toolbar, and bare text over street names cannot be read.
        ToolbarItem(placement: .navigation) { dayTitle }
        ToolbarItem(placement: .navigation) {
            Picker("Period", selection: Binding(get: { model.period }, set: { model.setPeriod($0) })) {
                ForEach(LocationPeriod.allCases) { period in
                    Text(period.name).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        // Only once the window has stepped back: on the latest period there
        // is nowhere for it to go, and All has no other period. Last on the
        // left, so it comes and goes without moving anything else.
        if model.canStep && !model.isToday {
            ToolbarItem(placement: .navigation) {
                Button("Today") { model.showToday() }
                    .help(
                        model.period == .day
                            ? "Back to today"
                            : "Back to the \(model.period.name.lowercased()) that ends today"
                    )
            }
        }

        // The left of the toolbar is which days are shown; the right, pushed
        // there by the spacer, is how the map draws them.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("Map", selection: $mapMode) {
                Label("Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .tag(MapMode.route)
                Label("Heat", systemImage: "flame")
                    .tag(MapMode.heat)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .labelsHidden()
            .fixedSize()
            .help(
                mapMode == .route
                    ? "Showing the route by time. Heat shows where you go most."
                    : "Showing where you go most. Route shows the track by time."
            )
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Add Place…") { model.sheet = .adding }
                Button("All Places (\(model.places.count))…") { model.sheet = .listing }
            } label: {
                Label("Places", systemImage: "mappin.and.ellipse")
            }
            .help("Name a place, or see every place you have named")
        }
        ToolbarItem(placement: .primaryAction) {
            ReloadButton(isLoading: model.isLoading) {
                Task { await model.reload() }
            }
        }
    }

    /// The panel's own part of the toolbar, empty: declaring it makes the
    /// toolbar end at the panel's edge, so the map's controls end there too
    /// instead of running over the device's name.
    @ToolbarContentBuilder
    private var panelToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }
    }

    private var dayTitle: some View {
        let title = LocationTimelineItems.periodTitle(lastDay: model.selectedDay, days: model.period.days)
        return Text(title)
            .font(.headline)
            .lineLimit(1)
            .frame(minWidth: DesignTokens.Size.locationDateWidth)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .fixedSize()
            .contentTransition(.numericText())
            .motion(.quick, value: title)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The reload arrow turns into a spinner in the same spot while a reload
/// runs, so the button keeps its size and place.
private struct ReloadButton: View {
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: "arrow.clockwise")
                    .opacity(isLoading ? 0 : 1)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity)
                }
            }
            .frame(width: DesignTokens.Size.statusIcon, height: DesignTokens.Size.statusIcon)
            .motion(.quick, value: isLoading)
        }
        .help("Reload from the recorded history")
        .accessibilityLabel(isLoading ? "Reloading" : "Reload")
    }
}

/// One line that starts as "Checking status…" and turns into the status. The
/// icon is decoration; the words beside it say the same thing.
private struct HealthStrip: View, Equatable {
    let health: LocationWindowModel.Health?
    let error: String?

    /// When the device was last seen, while all is well; the whole line
    /// while something is not.
    private var summary: String {
        guard let health else { return "Checking status…" }
        return health.level == .ok ? health.lastSeen : health.line
    }

    var body: some View {
        let failure = health?.failure ?? error
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
            Image(systemName: health?.level.symbolName ?? "circle.dotted")
                .foregroundStyle(health?.level.color ?? Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: DesignTokens.Size.statusIcon)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(summary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                if let failure {
                    Text(failure)
                        .foregroundStyle(DesignTokens.StatusColor.problem)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(failure)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
        }
        // The rest of the line (the account, how often it records) is a
        // hover away: it only matters when something is wrong, and then it
        // is the line.
        .help(health?.line ?? "")
        .font(DesignTokens.Typography.detail)
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.md + DesignTokens.Spacing.xs)
        .motion(.surface, value: health)
        .motion(.surface, value: failure)
    }
}
