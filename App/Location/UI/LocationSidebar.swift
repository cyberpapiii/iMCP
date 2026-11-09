import SwiftUI

struct LocationSidebar: View, Equatable {
    /// Not observed: the values below are what this view draws.
    let model: LocationWindowModel
    let summary: String?
    let range: Range<Date>?
    let items: [LocationTimelineItems.Item]
    let lookups: [String: LocationTimelineItems.StopLookup]
    let isLoading: Bool

    nonisolated static func == (lhs: LocationSidebar, rhs: LocationSidebar) -> Bool {
        lhs.summary == rhs.summary && lhs.range == rhs.range && lhs.items == rhs.items
            && lhs.lookups == rhs.lookups && lhs.isLoading == rhs.isLoading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Present from the first frame, so the list below never moves down.
            // The device is the title; what was found is the line under it.
            let parts = (summary ?? "Reading the recorded history…").split(separator: " · ", maxSplits: 1)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(parts.first.map(String.init) ?? "")
                    .font(DesignTokens.Typography.sectionHeader)
                Text(parts.count > 1 ? String(parts[1]) : " ")
                    .font(DesignTokens.Typography.detail)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .contentTransition(.opacity)
            .frame(maxWidth: .infinity, minHeight: DesignTokens.Size.windowToolbarHeight, alignment: .leading)
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .motion(.surface, value: summary)
            Divider()
            // A new period is a new list that fades in over the old one. The
            // same period reloaded keeps its list, scroll position and all.
            ZStack {
                list
                    .id(range)
                    .transition(.opacity)
            }
            .opacity(isLoading && range != nil ? DesignTokens.Opacity.working : 1)
            .motion(.surface, value: range)
            .motion(.quick, value: isLoading)
        }
    }

    private var list: some View {
        List(selection: Binding(get: { model.selectedItemID }, set: { model.selectedItemID = $0 })) {
            if range == nil {
                ForEach(0 ..< 4, id: \.self) { _ in
                    StopRowPlaceholder()
                        .selectionDisabled()
                }
            } else if spansSeveralDays {
                // Several days read as several days: each under its own name.
                ForEach(LocationTimelineItems.days(items), id: \.day) { day in
                    Section {
                        rows(day.items)
                    } header: {
                        Text(day.day, format: .dateTime.weekday(.wide).month().day())
                            .font(DesignTokens.Typography.sectionHeader)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                rows(items)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if range != nil, items.isEmpty {
                Text("Nothing recorded in this period.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var spansSeveralDays: Bool {
        guard let range else { return false }
        return range.upperBound.timeIntervalSince(range.lowerBound) > 26 * 3600
    }

    private func rows(_ items: [LocationTimelineItems.Item]) -> some View {
        ForEach(items) { item in
            row(item)
                .tag(item.id)
                .listRowBackground(card(for: item))
                .listRowSeparator(.hidden)
        }
    }

    /// A stop sits on a card, as a Settings row does. A gap between stops
    /// has none: it is the space between two cards.
    @ViewBuilder
    private func card(for item: LocationTimelineItems.Item) -> some View {
        switch item {
        case .visit:
            RoundedRectangle(cornerRadius: DesignTokens.Radius.callout)
                .fill(Color.primary.opacity(DesignTokens.Opacity.hover))
                .padding(.vertical, DesignTokens.Spacing.xxs)
                .padding(.horizontal, DesignTokens.Spacing.md)
        case .gap:
            Color.clear
        }
    }

    @ViewBuilder
    private func row(_ item: LocationTimelineItems.Item) -> some View {
        switch item {
        case .visit(let visit, let recurrence):
            StopRow(model: model, visit: visit, recurrence: recurrence, lookup: lookups[item.id])
                .equatable()
                .padding(.horizontal, DesignTokens.Spacing.md)
        case .gap(let gap):
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: DesignTokens.Size.statusIcon)
                    .accessibilityHidden(true)
                Text(LocationTimelineItems.gapText(gap))
                    .font(DesignTokens.Typography.detail)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, DesignTokens.Spacing.xs)
        }
    }
}

/// One stop in the list. Every line it will ever show has its room from the
/// first frame: an unnamed stop's name and its nearby venues are looked up
/// after the row is drawn, and they arrive in place.
private struct StopRow: View, Equatable {
    /// Not observed: the values below are what this view draws.
    let model: LocationWindowModel
    let visit: Visit
    let recurrence: Int
    /// Nil while an unnamed stop is still being looked up.
    let lookup: LocationTimelineItems.StopLookup?

    nonisolated static func == (lhs: StopRow, rhs: StopRow) -> Bool {
        lhs.visit == rhs.visit && lhs.recurrence == rhs.recurrence && lhs.lookup == rhs.lookup
    }

    private var isLookingUp: Bool { visit.place == nil && lookup == nil }
    @State private var isHovered = false

    var body: some View {
        let kind = LocationTimelineItems.StopKind(visit.place)
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: kind.symbolName)
                    .foregroundStyle(kind.colour)
                    .frame(width: DesignTokens.Size.statusIcon)
                    .accessibilityHidden(true)
                Text(LocationTimelineItems.stopTitle(place: visit.place, lookup: lookup))
                    .font(DesignTokens.Typography.sectionHeader)
                    .lineLimit(1)
                    .redacted(reason: isLookingUp ? .placeholder : [])
                    .contentTransition(.opacity)
                    .accessibilityLabel(
                        isLookingUp
                            ? "Looking up this place"
                            : LocationTimelineItems.stopTitle(place: visit.place, lookup: lookup)
                    )
                Spacer(minLength: DesignTokens.Spacing.sm)
                Text(LocationTimelineItems.duration(visit.observedDuration))
                    .font(DesignTokens.Typography.detail)
                    .foregroundStyle(.secondary)
            }
            // How the stay ended is in the gap row that follows, or in the
            // help; the card keeps to when it was.
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(
                    "\(LocationTimelineItems.clock(visit.arrival)) – \(LocationTimelineItems.clock(visit.lastObserved))"
                )
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if visit.place != nil {
                    Button("Rename…") { model.sheet = .naming(visit) }
                        .buttonStyle(.link)
                        .opacity(isHovered ? 1 : 0)
                        .accessibilityHidden(!isHovered)
                }
            }
            .font(DesignTokens.Typography.detail)
            .padding(.leading, DesignTokens.Size.statusIcon + DesignTokens.Spacing.sm)
            if visit.place == nil {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    if let near = visit.nearestPlace, let meters = visit.nearestPlaceMeters {
                        Text(StayName.distance(meters, from: near.name))
                            .font(DesignTokens.Typography.detail)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    nearby
                    HStack(spacing: DesignTokens.Spacing.md) {
                        if recurrence > 1 {
                            Text("Seen \(recurrence) times")
                                .font(DesignTokens.Typography.detail)
                                .padding(.horizontal, DesignTokens.Spacing.sm)
                                .padding(.vertical, DesignTokens.Spacing.hairline)
                                .background(kind.colour.opacity(0.2), in: Capsule())
                        }
                        Button("Name this place…") { model.sheet = .naming(visit) }
                            .buttonStyle(.link)
                            .font(DesignTokens.Typography.detail)
                    }
                }
                .padding(.leading, DesignTokens.Size.statusIcon + DesignTokens.Spacing.sm)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(LocationTimelineItems.endingText(visit))
        .contextMenu {
            Button(visit.place == nil ? "Name this place…" : "Rename…") { model.sheet = .naming(visit) }
        }
        .motion(.surface, value: lookup)
        .motion(.quick, value: isHovered)
    }

    /// One line, always there for an unnamed stop: first that the lookup is
    /// running, then what it found.
    private var nearby: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if let suggestion = lookup?.suggestion {
                Text("Maybe \(suggestion.name)?")
                    .italic()
                    .lineLimit(1)
                Button("Use this") {
                    Task { await model.accept(suggestion, for: visit) }
                }
                .buttonStyle(.link)
            } else {
                Text(nearbyText)
                    .foregroundStyle(lookup?.venues.isEmpty == false ? .secondary : .tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
                    .help(lookup?.venues.isEmpty == false ? nearbyText : "")
            }
        }
        .font(DesignTokens.Typography.detail)
    }

    private var nearbyText: String {
        guard let lookup else { return "Looking nearby…" }
        guard !lookup.venues.isEmpty else { return "Nothing listed nearby" }
        return "Could be "
            + lookup.venues.map { "\($0.name) (\(wholeMeters($0.meters)) m)" }.joined(separator: ", ")
    }
}

/// Stands where a stop will be while the history is first read.
private struct StopRowPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("A place with a name")
                .font(DesignTokens.Typography.sectionHeader)
            Text("12:00 AM – 12:00 PM")
        }
        .font(DesignTokens.Typography.detail)
        .redacted(reason: .placeholder)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .accessibilityHidden(true)
    }
}
