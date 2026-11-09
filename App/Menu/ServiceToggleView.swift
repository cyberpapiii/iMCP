import AppKit
import SwiftUI

/// One service in the menu's grid: its round icon, coloured while it is on,
/// and its name under it. The whole tile is the switch. A service that is on
/// but cannot reach its data shows a badge on the icon; the badge asks for
/// the permission.
struct ServiceToggleView: View {
    let config: ServiceSwitch
    /// The toggle's value, read by the parent. `config` is cached and never
    /// changes, so without a changing input SwiftUI skips this view's body and
    /// the icon keeps showing the old state.
    let isOn: Bool
    /// Whether the service can reach its data, read by the parent from
    /// `AppStatus.serviceAccess`. Nil while it is still being checked, so the
    /// warning badge does not flash on every menu open.
    let isActivated: Bool?
    let guidance: GuidanceRouter

    private var needsAttention: Bool {
        isOn && isActivated == false
    }

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private typealias Size = DesignTokens.Size

    var body: some View {
        Button {
            if config.isEnabled {
                config.isEnabled = false
            } else {
                guidance.switchOn(config)
            }
        } label: {
            VStack(spacing: DesignTokens.Spacing.xs) {
                icon
                Text(config.name)
                    .font(DesignTokens.Typography.detail)
                    .foregroundStyle(isOn ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.callout)
                        .fill(Color.primary.opacity(DesignTokens.Opacity.hover))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .overlay(alignment: .top) { badge }
        .accessibilityLabel(config.name)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .motion(.quick, value: isOn)
        .motion(.quick, value: needsAttention)
        .motion(.quick, value: isHovered)
    }

    private var icon: some View {
        Image(systemName: ServicePresentation.of(config.id).iconName)
            .resizable()
            .scaledToFit()
            .foregroundColor(isOn ? .white : .primary.opacity(0.7))
            .padding(Size.serviceTileIconInset)
            .frame(width: Size.serviceTileIcon, height: Size.serviceTileIcon)
            .glassFill(tint: iconTint, in: Circle())
    }

    /// Sits on the icon's top trailing edge, outside the tile's own button,
    /// so a click on it grants access instead of switching the service off.
    @ViewBuilder
    private var badge: some View {
        if needsAttention, let grantLabel = config.permission.explanation {
            Button {
                Task { await guidance.grantAccess(to: config) }
            } label: {
                Image(systemName: StatusSummary.Level.attention.symbolName)
                    .font(.system(size: Size.serviceBadge, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, StatusSummary.Level.attention.color)
            }
            .buttonStyle(.plain)
            .offset(x: Size.serviceTileIcon / 2, y: DesignTokens.Spacing.xxs)
            .help(grantLabel)
            .accessibilityLabel(grantLabel)
            .transition(.reveal(.quick))
        }
    }

    private var iconTint: Color {
        isOn
            ? ServicePresentation.of(config.id).color
            : Color(NSColor.controlColor).opacity(colorScheme == .dark ? 0.8 : 0.2)
    }
}
