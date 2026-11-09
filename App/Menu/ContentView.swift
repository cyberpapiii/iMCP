import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var serverController: ServerController
    @ObservedObject var appStatus: AppStatusModel
    @Binding var isMenuPresented: Bool
    let showConnectClient: @MainActor () -> Void
    let showLocationWindow: @MainActor () -> Void
    let showSettings: @MainActor () -> Void
    let guidance: GuidanceRouter

    private var serviceSwitches: [ServiceSwitch] {
        serverController.serviceSwitches
    }

    var body: some View {
        // Each `isEnabled` is a read from storage, so the toggles are read
        // once here and everything below works from the answer.
        let enabledIDs = Set(serviceSwitches.filter(\.isEnabled).map(\.id))
        let isServerEnabled = serverController.isServerEnabled
        let locationIsEnabled = serverController.isLocationEnabled
        let troubledRows = appStatus.status.rowsNeedingOwner
        let serviceAccess = appStatus.status.serviceAccess

        VStack(alignment: .leading, spacing: 0) {
            header(isServerEnabled: isServerEnabled, overall: appStatus.status.overall)

            // The header's word already says whether all is well. Only what
            // needs the owner is listed, right under it, as the reason.
            if !troubledRows.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    ForEach(troubledRows) { row in
                        statusRow(
                            level: row.summary.level,
                            title: row.summary.title,
                            detail: row.summary.detail,
                            hint: row.hint
                        ) {
                            open(row.destination)
                        }
                        .transition(.reveal())
                    }
                }
                .padding(.top, Spacing.sm)
                .padding(.horizontal, Spacing.sm)
                .transition(.reveal())
            }

            if isServerEnabled {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    inset(Divider())
                        .padding(.bottom, Spacing.xs)

                    // The tiles take `enabledIDs` and `serviceAccess` from
                    // outside the closure. The configs are cached, so a closure
                    // that captures nothing new makes this `ForEach` identical
                    // to the last one and SwiftUI never asks it for the tiles
                    // again.
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 0),
                            count: DesignTokens.Size.serviceColumns
                        ),
                        spacing: Spacing.xxs
                    ) {
                        ForEach(serviceSwitches) { config in
                            ServiceToggleView(
                                config: config,
                                isOn: enabledIDs.contains(config.id),
                                isActivated: serviceAccess[config.id],
                                guidance: guidance
                            )
                        }
                    }
                    .padding(.horizontal, Spacing.md)
                }
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.xs)
                .transition(.reveal())
            }

            inset(Divider())
                .padding(.top, Spacing.sm)

            footer(locationIsEnabled: locationIsEnabled)
        }
        .padding(.vertical, Spacing.sm)
        .frame(width: DesignTokens.Size.menuPanelWidth)
        .motion(.surface, value: isServerEnabled)
        .motion(.surface, value: locationIsEnabled)
        .motion(.surface, value: troubledRows)
        .background(DesignTokens.panelMaterial)
        .onAppear { appStatus.refresh() }
    }

    /// The menu's own commands, as rows the way a menu lists them: the name
    /// on the left, its shortcut on the right, and Quit last on its own.
    private func footer(locationIsEnabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            commandRow("Connect a Client…", action: showConnectClient)
            if locationIsEnabled {
                commandRow("Location…", action: showLocationWindow)
                    .transition(.reveal(.quick))
            }
            commandRow("Settings…", shortcut: ",", action: showSettings)
            inset(Divider())
                .padding(.vertical, Spacing.sm)
            commandRow("Quit iMCP", shortcut: "q") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.top, Spacing.sm)
    }

    private func commandRow(
        _ title: String,
        shortcut: KeyEquivalent? = nil,
        action: @escaping () -> Void
    ) -> some View {
        MenuButton(isMenuPresented: $isMenuPresented, action: action) {
            HStack {
                Text(title)
                Spacer(minLength: Spacing.md)
                if let shortcut {
                    Text("⌘\(String(shortcut.character).uppercased())")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, Spacing.xs)
            .padding(.horizontal, Spacing.md)
            .contentShape(Rectangle())
        }
        .keyboardShortcut(shortcut.map { KeyboardShortcut($0, modifiers: .command) })
        .padding(.horizontal, Spacing.sm)
    }

    /// A divider inset to the text's margin, as Rex and the system menus
    /// draw them, so every edge in the panel lines up on one gutter.
    private func inset(_ divider: Divider) -> some View {
        divider.padding(.horizontal, Spacing.lg)
    }

    static let masterSwitchLabel = "Let agents use this Mac"

    /// The app's icon and name, a dot and a word for how it is, and the
    /// switch that turns it on and off. The word is the menu-bar icon's state
    /// said out loud; the Status section below says why.
    private func header(isServerEnabled: Bool, overall: OverallStatus) -> some View {
        let state = ServerStateBadge(isServerEnabled: isServerEnabled, level: overall.level)
        return HStack(spacing: Spacing.md + Spacing.xs) {
            AppIconImage(size: DesignTokens.Size.menuHeaderIcon)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text("iMCP")
                    .font(DesignTokens.Typography.menuHeaderTitle)
                HStack(spacing: Spacing.sm) {
                    Circle()
                        .fill(state.color)
                        .frame(width: DesignTokens.Size.statusDot, height: DesignTokens.Size.statusDot)
                    Text(state.word)
                        .font(DesignTokens.Typography.detail)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            Toggle(Self.masterSwitchLabel, isOn: $serverController.isServerEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .help(Self.masterSwitchLabel)
        }
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.xxs)
        .padding(.horizontal, Spacing.lg)
        .motion(.quick, value: state)
    }

    private typealias Spacing = DesignTokens.Spacing

    private func open(_ destination: StatusDestination) {
        switch destination {
        case .fullDiskAccessPane: guidance.openFullDiskAccessSettings()
        case .settings: showSettings()
        case .iCloudSignIn: guidance.showICloudSignIn()
        }
    }

    /// A status line: an icon whose outline and colour say the level, a
    /// title, and up to two lines of detail. The icon is decoration to
    /// VoiceOver, which reads the words and `hint`.
    private func statusRow(
        level: StatusSummary.Level,
        title: String,
        detail: String?,
        hint: String,
        action: @escaping () -> Void
    ) -> some View {
        MenuButton(isMenuPresented: $isMenuPresented, action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                Image(systemName: level.symbolName)
                    .font(DesignTokens.Typography.detail)
                    .foregroundStyle(level.color)
                    .frame(width: DesignTokens.Size.statusIcon)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(DesignTokens.Typography.detail)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, Spacing.xs)
            .padding(.horizontal, Spacing.md)
            .contentShape(Rectangle())
        }
        .accessibilityHint(hint)
    }
}

/// A button in the menu: runs its action, closes the menu, and highlights
/// under the pointer and under keyboard focus.
///
/// `isMenuPresented` is kept true by MenuBarExtraAccess only where that
/// library can find the status item. Where it cannot (macOS 27), the binding
/// stays false while the panel is plainly open, setting it false again does
/// nothing, and the panel stayed up behind the window the row had opened.
/// SwiftUI's own `dismiss` closes it there. Only one of the two runs, because
/// both together would toggle the panel twice.
private struct MenuButton<Label: View>: View {
    @Binding var isMenuPresented: Bool
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            let bindingKnowsThePanelIsOpen = isMenuPresented
            action()
            if bindingKnowsThePanelIsOpen {
                isMenuPresented = false
            } else {
                dismiss()
            }
        } label: {
            label
        }
        .buttonStyle(MenuItemButtonStyle(isHighlighted: isHovered || isFocused))
        .focused($isFocused)
        .onHover { isHovered = $0 }
    }
}

/// Highlighted in the accent colour under the pointer, as a menu item is.
private struct MenuItemButtonStyle: ButtonStyle {
    var isHighlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background {
                if configuration.isPressed || isHighlighted {
                    Color.clear.glassFill(
                        tint: Color.accentColor.opacity(configuration.isPressed ? 1.0 : 0.7),
                        in: RoundedRectangle(cornerRadius: DesignTokens.Radius.row)
                    )
                }
            }
            .contentShape(Rectangle())
    }
}
