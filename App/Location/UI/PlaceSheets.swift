import AppKit
import CoreLocation
import MapKit
import SwiftUI

/// What every place sheet shares: a title and a caption that stay at the
/// top, the buttons that stay at the bottom, and between them the part that
/// changes. A save or delete that failed says so above the buttons, and the
/// sheet stays open with everything typed still in it.
private struct PlaceSheetFrame<Content: View, Actions: View>: View {
    let title: String
    let caption: String
    let error: String?
    /// The new place this sheet has just saved, and how the sheet closes.
    /// The save is already done: the sheet stays only long enough to mark it.
    var saved: String?
    var close: () -> Void = {}
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            Text(title)
                .font(DesignTokens.Typography.sheetTitle)
            Text(caption)
                .font(DesignTokens.Typography.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content
            if let error {
                Label(error, systemImage: StatusSummary.Level.attention.symbolName)
                    .font(DesignTokens.Typography.detail)
                    .foregroundStyle(DesignTokens.StatusColor.problem)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.reveal())
            }
            HStack(spacing: DesignTokens.Spacing.md) {
                Spacer(minLength: 0)
                actions
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: DesignTokens.Size.sheetWidth)
        .motion(.surface, value: error)
        .task(id: saved) {
            guard saved != nil else { return }
            try? await Task.sleep(for: DesignTokens.Linger.ceremony)
            if !Task.isCancelled { close() }
        }
    }
}

/// Rows in a sheet. As tall as its rows until that passes the sheet's list
/// maximum, and from there it scrolls.
private struct FittedList<Rows: View>: View {
    @ViewBuilder let rows: Rows

    var body: some View {
        ViewThatFits(in: .vertical) {
            stack
            ScrollView { stack }
        }
        .frame(maxHeight: DesignTokens.Size.sheetListMaxHeight)
        .background(.quaternary.opacity(DesignTokens.Opacity.working), in: shape)
        .clipShape(shape)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: DesignTokens.Radius.callout) }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 0) { rows }
            .padding(DesignTokens.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RadiusRow: View {
    @Binding var radius: Double
    /// Fixed when the sheet opens, from the radius it opened with.
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Text("Radius")
            Slider(value: $radius, in: range, step: 10)
                .accessibilityLabel("Radius")
                .accessibilityValue("\(wholeMeters(radius)) metres")
            Text("\(wholeMeters(radius)) m")
                .monospacedDigit()
                .frame(width: DesignTokens.Size.radiusValueWidth, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}

@MainActor
private func copyCoordinates(latitude: Double, longitude: Double) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(
        LocationTimelineItems.coordinatesText(latitude: latitude, longitude: longitude),
        forType: .string
    )
}

struct NamePlaceSheet: View {
    @ObservedObject var model: LocationWindowModel
    let visit: Visit

    @State private var name = ""
    @State private var radius = LocationPolicy.PlaceRadius.sheetDefault
    @State private var radiusRange = LocationPolicy.PlaceRadius.slider()
    @State private var candidates: [NearbyVenue] = []
    @State private var pick = ""
    @State private var looking = true
    @State private var kind = NamedPlaceKind.label
    @FocusState private var nameIsFocused: Bool

    var body: some View {
        PlaceSheetFrame(
            title: visit.place.map { "Rename \($0.name)" } ?? "Name this place",
            caption:
                "Visits within \(wholeMeters(radius)) m of this spot are reported by this name, here and to agents.",
            error: model.placeError,
            saved: model.savedPlace,
            close: { model.sheet = nil }
        ) {
            Text(spotLine)
                .font(DesignTokens.Typography.detail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("Right-click to copy this spot's coordinates")
                .contextMenu {
                    Button("Copy Coordinates") {
                        copyCoordinates(latitude: visit.latitude, longitude: visit.longitude)
                    }
                }

            HStack(spacing: DesignTokens.Spacing.md) {
                Text("Nearby")
                Picker("Nearby", selection: $pick) {
                    Text(
                        candidates.isEmpty
                            ? (looking ? "Looking up…" : "Nothing listed nearby") : "Pick from Apple Maps…"
                    )
                    .tag("")
                    ForEach(candidates, id: \.name) { venue in
                        Text("\(venue.name) · \(wholeMeters(venue.meters)) m").tag(venue.name)
                    }
                }
                .labelsHidden()
                .disabled(candidates.isEmpty)
                .onChange(of: pick) { _, chosen in
                    guard !chosen.isEmpty else { return }
                    name = chosen
                    radius = LocationPolicy.PlaceRadius.storefront
                }
            }
            .help("Businesses within reach of this visit, closest first. A guess to pick from, not a finding.")

            TextField("Name (Home, Gym, Office…)", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameIsFocused)
                .onSubmit(save)

            RadiusRow(radius: $radius, range: radiusRange)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Picker("Kind", selection: $kind) {
                    Text("Name this visit only").tag(NamedPlaceKind.label)
                    Text("Save as one of my places").tag(NamedPlaceKind.notable)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                // Room for the longer of the two, so choosing moves nothing.
                Text(
                    kind == NamedPlaceKind.notable
                        ? "Shown on the map, and agents treat it as one of your places."
                        : "Names visits here without adding this spot to your map or your places."
                )
                .font(DesignTokens.Typography.detail)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .contentTransition(.opacity)
                .motion(.quick, value: kind)
            }
        } actions: {
            Button("Cancel") { model.sheet = nil }
                .keyboardShortcut(.cancelAction)
            Button(action: save) {
                DoneLabel(title: "Save", isDone: model.savedPlace != nil, announcement: "Place saved")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(NamedPlace.name(from: name) == nil)
        }
        .defaultFocus($nameIsFocused, true)
        .onAppear {
            if let place = visit.place {
                name = place.name
                radius = place.radiusMeters
                radiusRange = LocationPolicy.PlaceRadius.slider(including: place.radiusMeters)
                kind = place.kind
            }
            nameIsFocused = true
        }
        .task {
            candidates = await model.candidates(for: visit)
            looking = false
        }
    }

    /// Where and when, in words: the street if it is already known, and the
    /// hours of the visit.
    private var spotLine: String {
        let hours =
            "\(LocationTimelineItems.clock(visit.arrival)) to \(LocationTimelineItems.clock(visit.lastObserved))"
        guard let street = model.cachedStreet(latitude: visit.latitude, longitude: visit.longitude) else {
            return hours
        }
        return "\(street) · \(hours)"
    }

    private func save() {
        // Already saved: a second press only closes the sheet sooner.
        guard model.savedPlace == nil else {
            model.sheet = nil
            return
        }
        let visit = visit
        let name = name
        let radius = radius
        let kind = kind
        Task { await model.name(visit, as: name, radiusMeters: radius, kind: kind) }
    }
}

/// Name a place by searching for it. The selected result's coordinate is
/// preserved so the saved place keeps the address the user chose.
struct AddPlaceSheet: View {
    enum Search: Equatable {
        case idle
        case found([MKMapItem])
        case nothingFound(query: String)
        case failed(String)
    }

    private enum Field {
        case query
        case name
    }

    private struct Choice: Equatable {
        let title: String
        let address: String
        let latitude: Double
        let longitude: Double

        init(_ item: MKMapItem) {
            title = item.name ?? "Unnamed"
            address = AddPlaceSheet.address(of: item)
            latitude = item.placemark.coordinate.latitude
            longitude = item.placemark.coordinate.longitude
        }

        init(place: NamedPlace, address: LocationTimelineItems.PlaceAddress?) {
            title = place.name
            switch address {
            case .street(let street): self.address = street
            case .unknown: self.address = "No street address"
            case nil:
                self.address = LocationTimelineItems.coordinatesText(
                    latitude: place.latitude,
                    longitude: place.longitude
                )
            }
            latitude = place.latitude
            longitude = place.longitude
        }
    }

    @ObservedObject var model: LocationWindowModel
    let editing: NamedPlace?

    @State private var query = ""
    @State private var search: Search
    @State private var isSearching = false
    @State private var chosen: Choice?
    @State private var name: String
    @State private var radius: Double
    private let radiusRange: ClosedRange<Double>
    @FocusState private var focus: Field?

    init(
        model: LocationWindowModel,
        search: Search = .idle,
        editing: NamedPlace? = nil,
        address: LocationTimelineItems.PlaceAddress? = nil
    ) {
        self.model = model
        self.editing = editing
        _search = State(initialValue: search)
        _chosen = State(initialValue: editing.map { Choice(place: $0, address: address) })
        _name = State(initialValue: editing?.name ?? "")
        _radius = State(initialValue: editing?.radiusMeters ?? LocationPolicy.PlaceRadius.sheetDefault)
        radiusRange = LocationPolicy.PlaceRadius.slider(including: editing?.radiusMeters)
    }

    var body: some View {
        PlaceSheetFrame(
            title: editing.map { "Edit \($0.name)" } ?? "Add a place",
            caption: editing == nil
                ? "Search for an address or a venue, then give it the name you use for it."
                : "Change its name, address, or radius.",
            error: model.placeError,
            saved: model.savedPlace,
            close: close
        ) {
            if let chosen {
                namingStage(chosen)
                    .transition(.reveal())
            } else {
                searchStage
                    .transition(.reveal())
            }
        } actions: {
            Button("Cancel", action: close)
                .keyboardShortcut(.cancelAction)
            Button(action: save) {
                DoneLabel(
                    title: editing == nil ? "Add Place" : "Save Changes",
                    isDone: model.savedPlace != nil,
                    announcement: "Place saved"
                )
            }
            .keyboardShortcut(.defaultAction)
            .disabled(chosen == nil || NamedPlace.name(from: name) == nil)
        }
        .motion(.surface, value: chosen)
        .motion(.surface, value: search)
        .motion(.quick, value: isSearching)
        .defaultFocus($focus, .query)
        .onAppear { focus = editing == nil ? .query : .name }
    }

    private var searchStage: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            HStack(spacing: DesignTokens.Spacing.md) {
                TextField("Address or venue name", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .query)
                    .onSubmit(runSearch)
                Button("Search", action: runSearch)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
            }

            // Always here: first what to type, then that it is searching,
            // then what came back.
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                ZStack {
                    Image(systemName: Self.statusSymbol(search))
                        .opacity(isSearching ? 0 : 1)
                    if isSearching {
                        ProgressView()
                            .controlSize(.small)
                            .transition(.opacity)
                    }
                }
                .frame(width: DesignTokens.Size.statusIcon)
                .accessibilityHidden(true)
                Text(isSearching ? "Searching…" : Self.statusText(search))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .font(DesignTokens.Typography.detail)
            .foregroundStyle(
                statusIsProblem ? AnyShapeStyle(DesignTokens.StatusColor.problem) : AnyShapeStyle(.secondary)
            )

            if case .found(let items) = search {
                FittedList {
                    ForEach(items, id: \.self) { item in
                        SearchResultRow(title: item.name ?? "Unnamed", detail: Self.address(of: item)) {
                            select(item)
                        }
                    }
                }
                .opacity(isSearching ? DesignTokens.Opacity.working : 1)
                .transition(.reveal())
            }
        }
    }

    private var statusIsProblem: Bool {
        if case .failed = search, !isSearching { return true }
        return false
    }

    static func statusText(_ search: Search) -> String {
        switch search {
        case .idle:
            return "Type a street address or the name of a venue, then press Return."
        case .found(let items):
            return items.count == 1
                ? "1 result. Click it to use it." : "\(items.count) results. Click the one you mean."
        case .nothingFound(let query):
            return "Nothing found for \u{201C}\(query)\u{201D}. Try the full street address or another spelling."
        case .failed(let message):
            return message
        }
    }

    static func statusSymbol(_ search: Search) -> String {
        switch search {
        case .idle: return "magnifyingglass"
        case .found: return "list.bullet"
        case .nothingFound: return "questionmark.circle"
        case .failed: return StatusSummary.Level.attention.symbolName
        }
    }

    private func namingStage(_ chosen: Choice) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack {
                    Text(chosen.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: DesignTokens.Spacing.md)
                    Button(editing == nil ? "Change" : "Change Address") {
                        self.chosen = nil
                        focus = .query
                    }
                    .buttonStyle(.link)
                    .help("Go back to the search results")
                }
                Text(chosen.address)
                    .font(DesignTokens.Typography.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Label("Centred on the selected address.", systemImage: "mappin")
                    .font(DesignTokens.Typography.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .contentTransition(.opacity)
            }
            TextField("Name (Office, Home, Mom's…)", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .name)
            RadiusRow(radius: $radius, range: radiusRange)
        }
    }

    private static func address(of item: MKMapItem) -> String {
        PlacemarkAddress(item.placemark).text(.streetAndLocality) ?? item.placemark.title ?? ""
    }

    private func runSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSearching else { return }
        Task { await search(for: text) }
    }

    private func select(_ item: MKMapItem) {
        chosen = Choice(item)
        if editing == nil { name = item.name ?? "" }
        focus = .name
    }

    private func search(for text: String) async {
        isSearching = true
        defer { isSearching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let latest = model.latest {
            request.region = MKCoordinateRegion(
                center: latest.coordinate,
                latitudinalMeters: 20_000,
                longitudinalMeters: 20_000
            )
        }
        do {
            let items = try await MKLocalSearch(request: request).start().mapItems
            search = items.isEmpty ? .nothingFound(query: text) : .found(items)
        } catch let error as MKError where error.code == .placemarkNotFound {
            // Maps reports "no match" as an error, not as an empty list.
            search = .nothingFound(query: text)
        } catch {
            search = .failed(
                sanitizedToolErrorMessage(
                    for: error,
                    fallback: "Search failed. Check your connection and try again."
                )
            )
        }
    }

    private func save() {
        // Already saved: a second press only closes the sheet sooner.
        guard model.savedPlace == nil else {
            close()
            return
        }
        guard let chosen else { return }
        let name = name
        let radius = radius
        Task {
            if let editing {
                await model.editPlace(
                    editing,
                    name: name,
                    latitude: chosen.latitude,
                    longitude: chosen.longitude,
                    radiusMeters: radius
                )
            } else {
                await model.addPlace(
                    name: name,
                    latitude: chosen.latitude,
                    longitude: chosen.longitude,
                    radiusMeters: radius
                )
            }
        }
    }

    private func close() {
        if editing == nil {
            model.sheet = nil
        } else {
            model.editingPlace = nil
        }
    }
}

private struct SearchResultRow: View {
    let title: String
    let detail: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(title)
                    .lineLimit(1)
                Text(detail)
                    .font(DesignTokens.Typography.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(
                Color.primary.opacity(isHovered ? DesignTokens.Opacity.hover : 0),
                in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(title), \(detail)")
    }
}

struct PlacesListSheet: View {
    @ObservedObject var model: LocationWindowModel
    @State private var pendingDelete: NamedPlace?

    var body: some View {
        PlaceSheetFrame(
            title: "Named places",
            caption: "Agents use these names. Anywhere else is described as \"near\" an address.",
            error: model.placeError
        ) {
            if model.places.isEmpty {
                Label(
                    "No places named yet. Name a stop in the list, or use Add Place.",
                    systemImage: LocationTimelineItems.StopKind.unnamed.symbolName
                )
                .font(DesignTokens.Typography.detail)
                .foregroundStyle(.secondary)
                .transition(.reveal())
            } else {
                FittedList {
                    section("My places", model.places.filter(\.isNotable))
                    section("Visit-only names", model.places.filter { !$0.isNotable })
                }
                .transition(.reveal())
            }
        } actions: {
            Button("Done", action: close)
                .keyboardShortcut(.defaultAction)
        }
        // Escape closes too. A button can hold one shortcut, so this one
        // carries the second and is never seen.
        .background {
            Button("Close", action: close)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .motion(.surface, value: model.places)
        .task(id: model.places) { await model.lookUpPlaceAddresses() }
        .confirmationDialog(
            "Delete \u{201C}\(pendingDelete?.name ?? "")\u{201D}?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { place in
            Button("Delete Place", role: .destructive) {
                Task { await model.deletePlace(place) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { place in
            Text(LocationTimelineItems.deleteWarningText(isNotable: place.isNotable))
        }
        .sheet(item: $model.editingPlace) { place in
            AddPlaceSheet(model: model, editing: place, address: model.placeAddresses[place.id])
        }
    }

    private func close() {
        model.sheet = nil
    }

    @ViewBuilder
    private func section(_ title: String, _ places: [NamedPlace]) -> some View {
        if !places.isEmpty {
            Text(title)
                .font(DesignTokens.Typography.detail.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.top, DesignTokens.Spacing.sm)
                .padding(.bottom, DesignTokens.Spacing.xxs)
                .accessibilityAddTraits(.isHeader)
            ForEach(places, id: \.id) { place in
                placeRow(place)
                    .transition(.reveal())
            }
        }
    }

    private func placeRow(_ place: NamedPlace) -> some View {
        let address = model.placeAddresses[place.id]
        let kind = LocationTimelineItems.StopKind(place)
        return HStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: kind.symbolName)
                .foregroundStyle(kind.colour)
                .frame(width: DesignTokens.Size.statusIcon)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(place.name)
                    .lineLimit(1)
                // Has its room from the first frame; the street arrives in it.
                Text(LocationTimelineItems.placeDetail(address: address, radiusMeters: place.radiusMeters))
                    .font(DesignTokens.Typography.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .redacted(reason: address == nil ? .placeholder : [])
                    .contentTransition(.opacity)
            }
            Spacer(minLength: DesignTokens.Spacing.md)
            Button {
                model.editingPlace = place
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit \(place.name)")
            .accessibilityLabel("Edit \(place.name)")
            Button(role: .destructive) {
                pendingDelete = place
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete \(place.name)")
            .accessibilityLabel("Delete \(place.name)")
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Coordinates") {
                copyCoordinates(latitude: place.latitude, longitude: place.longitude)
            }
            Divider()
            Button("Edit Place…") { model.editingPlace = place }
            Button("Delete Place…", role: .destructive) { pendingDelete = place }
        }
        .motion(.surface, value: address)
    }
}
