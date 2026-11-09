import AppKit
import SwiftUI

/// Settings as a sidebar and a page, like System Settings: iMCP's own state
/// at the top of the sidebar, then one page per area, with back and forward
/// through the pages visited.
struct SettingsView: View {
    @ObservedObject var serverController: ServerController
    @ObservedObject var appStatus: AppStatusModel
    let iCloud: ICloudSession
    let pairedClients: PairedClientStore
    let locationData: LocationDataLifecycle
    let showConnectClient: @MainActor () -> Void
    let showLocationWindow: @MainActor () -> Void
    let guidance: GuidanceRouter
    var isMenuBarExtraInserted: Bool
    @State private var selection: SettingsPane? = .overview
    @State private var history = SettingsHistory()
    @State private var search = ""
    /// The sidebar takes focus when the window opens, as System Settings'
    /// does, so the arrow keys move through the pages. Without it the search
    /// field would take the first keystroke and draw its ring unasked.
    @FocusState private var isSidebarFocused: Bool

    var body: some View {
        let pane = selection ?? .overview
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: DesignTokens.Size.settingsSidebarWidth,
                    ideal: DesignTokens.Size.settingsSidebarWidth,
                    max: DesignTokens.Size.settingsSidebarWidth
                )
        } detail: {
            // A new page fades in over the old one rather than replacing it
            // by a cut.
            ZStack {
                detail(for: pane)
                    .id(pane)
                    .transition(.opacity)
            }
            .motion(.quick, value: pane)
            .toolbar { pageToolbar(title: pane.title) }
            .toolbar(removing: .title)
        }
        .navigationTitle(pane.title)
        .frame(width: DesignTokens.Size.settingsWindowWidth, height: DesignTokens.Size.settingsWindowHeight)
        .onChange(of: selection) { _, pane in
            if let pane { history.visit(pane) }
        }
    }

    /// Back and Forward in one capsule, then the page's title beside it, not in it.
    @ToolbarContentBuilder
    private func pageToolbar(title: String) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ControlGroup {
                Button {
                    selection = history.back()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(!history.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                Button {
                    selection = history.forward()
                } label: {
                    Label("Forward", systemImage: "chevron.right")
                }
                .disabled(!history.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
            }
            .controlGroupStyle(.navigation)
        }
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) { pageTitle(title) }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { pageTitle(title) }
        }
    }

    private func pageTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .fixedSize()
            .contentTransition(.opacity)
            .motion(.quick, value: title)
            .accessibilityAddTraits(.isHeader)
    }

    /// Rows drawn here rather than a `List` with selection: a sidebar list
    /// marks its row in the accent colour, and this marks it in a quiet gray.
    private var sidebar: some View {
        let visible = SettingsPane.allCases.filter { $0.matches(search) }
        return ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                if visible.contains(.overview) {
                    sidebarRow(.overview) {
                        ServerSidebarRow(
                            state: ServerStateBadge(
                                isServerEnabled: serverController.isServerEnabled,
                                level: appStatus.status.overall.level
                            )
                        )
                    }
                }
                ForEach(SettingsPane.Group.allCases, id: \.self) { group in
                    let panes = visible.filter { $0.group == group }
                    if !panes.isEmpty {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                            ForEach(panes) { pane in
                                sidebarRow(pane) {
                                    HStack(spacing: DesignTokens.Spacing.md) {
                                        SettingsIcon(systemName: pane.systemImage, color: pane.color)
                                        SidebarTitle(text: pane.title)
                                    }
                                }
                            }
                        }
                        .padding(.top, DesignTokens.Spacing.md)
                    }
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.xs)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isSidebarFocused)
        .defaultFocus($isSidebarFocused, true)
        .onKeyPress(.upArrow) { step(by: -1, through: visible) }
        .onKeyPress(.downArrow) { step(by: 1, through: visible) }
        .searchable(text: $search, placement: .sidebar, prompt: "Search Settings")
        .onSubmit(of: .search) {
            if let first = visible.first { selection = first }
        }
        .toolbar(removing: .sidebarToggle)
        .motion(.quick, value: selection)
    }

    private func step(by offset: Int, through panes: [SettingsPane]) -> KeyPress.Result {
        guard !panes.isEmpty else { return .ignored }
        let current = selection.flatMap { panes.firstIndex(of: $0) } ?? -offset
        selection = panes[min(max(current + offset, 0), panes.count - 1)]
        return .handled
    }

    private func sidebarRow(_ pane: SettingsPane, @ViewBuilder label: () -> some View) -> some View {
        let isSelected = selection == pane
        return Button {
            selection = pane
        } label: {
            label()
                .environment(\.isSettingsRowSelected, isSelected)
                .frame(maxWidth: .infinity, minHeight: DesignTokens.Size.settingsSidebarRow, alignment: .leading)
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.callout)
                        .fill(isSelected ? Color.primary.opacity(DesignTokens.Opacity.well) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func detail(for pane: SettingsPane) -> some View {
        switch pane {
        case .overview:
            OverviewSettingsView(
                serverController: serverController,
                appStatus: appStatus,
                guidance: guidance,
                open: { selection = $0 }
            )
        case .general:
            GeneralSettingsView(isMenuBarExtraInserted: isMenuBarExtraInserted)
        case .permissions:
            PermissionsSettingsView(
                serverController: serverController,
                appStatus: appStatus,
                iCloud: iCloud,
                guidance: guidance
            )
        case .clients:
            ClientsSettingsView(pairedClientStore: pairedClients, showConnectClient: showConnectClient)
        case .location:
            Form {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                            Text("Location Window")
                            Text("See where your devices have been on a map, and name places.")
                                .font(DesignTokens.Typography.detail)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open", action: showLocationWindow)
                            .glassButtonStyle()
                    }
                }
                LocationSettingsSections(locationEnabled: serverController.isLocationEnabled, lifecycle: locationData)
            }
            .formStyle(.grouped)
        case .about:
            AboutSettingsView()
        }
    }
}

/// The top of the sidebar: the app's icon, its name, and its state in a word.
private struct ServerSidebarRow: View {
    let state: ServerStateBadge

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            AppIconImage(size: DesignTokens.Size.settingsServerIcon)
            VStack(alignment: .leading, spacing: 0) {
                SidebarTitle(text: "iMCP")
                Text(state.word)
                    .font(DesignTokens.Typography.detail)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
        .motion(.quick, value: state)
        .accessibilityElement(children: .combine)
    }
}

/// A sidebar row's name, in semibold while its page is showing. Only the
/// name: the line under it stays as it is.
private struct SidebarTitle: View {
    let text: String
    @Environment(\.isSettingsRowSelected) private var isSelected

    var body: some View {
        Text(text)
            .fontWeight(isSelected ? .semibold : .regular)
    }
}

extension EnvironmentValues {
    @Entry var isSettingsRowSelected = false
}

/// A card with nothing in it yet: what would be here, and how it gets here.
struct EmptyStateCard: View {
    let systemName: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: systemName)
                .font(.system(size: DesignTokens.Size.emptyStateIcon))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(DesignTokens.Typography.detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.Spacing.xl)
    }
}

/// iMCP's state and switch, then each thing it depends on, healthy or not.
/// The menu lists only what needs the owner; this page lists everything.
struct OverviewSettingsView: View {
    @ObservedObject var serverController: ServerController
    @ObservedObject var appStatus: AppStatusModel
    let guidance: GuidanceRouter
    let open: (SettingsPane) -> Void

    var body: some View {
        let status = appStatus.status
        let state = ServerStateBadge(isServerEnabled: serverController.isServerEnabled, level: status.overall.level)
        Form {
            Section {
                HStack(spacing: DesignTokens.Spacing.lg) {
                    AppIconImage(size: DesignTokens.Size.settingsHeroIcon)
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                        Text("iMCP")
                            .font(.headline)
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            Circle()
                                .fill(state.color)
                                .frame(width: DesignTokens.Size.statusDot, height: DesignTokens.Size.statusDot)
                            Text(state.word)
                                .foregroundStyle(.secondary)
                                .contentTransition(.opacity)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    Spacer()
                    Toggle(ContentView.masterSwitchLabel, isOn: $serverController.isServerEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help(ContentView.masterSwitchLabel)
                }
                .padding(.vertical, DesignTokens.Spacing.xs)
                .motion(.quick, value: state)
            }

            Section("Status") {
                ForEach(status.subjectRows) { row in
                    statusRow(row)
                }
            }
        }
        .formStyle(.grouped)
        .motion(.surface, value: status.subjectRows)
        .onAppear { appStatus.refresh() }
    }

    @ViewBuilder
    private func statusRow(_ row: AppStatus.Row) -> some View {
        let content = HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.md) {
            Image(systemName: row.summary.level.symbolName)
                .foregroundStyle(row.summary.level.color)
                .frame(width: DesignTokens.Size.statusIcon)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(row.summary.title)
                Text(row.summary.detail)
                    .font(DesignTokens.Typography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DesignTokens.Spacing.md)
        }
        switch row.subject {
        case .clients:
            NavigationRow(action: { open(.clients) }) { content }
        case .fullDiskAccess where row.summary.level != .ok:
            HStack {
                content
                Button("Grant…") { guidance.openFullDiskAccessSettings() }
                    .glassButtonStyle()
            }
        case .fullDiskAccess:
            NavigationRow(action: { open(.permissions) }) { content }
        case .iCloud:
            NavigationRow(action: { open(.permissions) }) { content }
        default:
            content
        }
    }
}

/// A row that opens another page: the whole row is the target, with a
/// chevron at its end.
private struct NavigationRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            HStack {
                content
                Image(systemName: "chevron.right")
                    .font(DesignTokens.Typography.detail.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A coloured tile with a white symbol, as System Settings draws its panes.
struct SettingsIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: DesignTokens.Typography.minimumSize, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: DesignTokens.Size.permissionIcon, height: DesignTokens.Size.permissionIcon)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.row)
                    .fill(color.gradient)
            )
            .accessibilityHidden(true)
    }
}

struct PermissionsSettingsView: View {
    @ObservedObject var serverController: ServerController
    @ObservedObject var appStatus: AppStatusModel
    /// Only for the iCloud row's buttons; what the row says comes from `appStatus`.
    let iCloud: ICloudSession
    let guidance: GuidanceRouter

    private enum AppPermission {
        case fullDiskAccess
        case iCloud
    }

    private var permissionConfigs: [ServiceSwitch] {
        serverController.serviceSwitches.filter { $0.permission.settingsDetail != nil }
    }

    var body: some View {
        // Each `isEnabled` is a read from storage, so the switches are read
        // once here and the rows are handed the answer. A row that read its
        // own would not be asked again when one flips in the menu.
        let enabledIDs = Set(serverController.serviceSwitches.filter(\.isEnabled).map(\.id))
        let status = appStatus.status
        let serviceStatus = { (config: ServiceSwitch) in
            enabledIDs.contains(config.id)
                ? ServicePermissionStatus(granted: status.serviceAccess[config.id]) : .notEnabled
        }
        let fullDiskAccess = ServicePermissionStatus(granted: status.fullDiskAccessGranted)
        let iCloudAccount = ServicePermissionStatus(status.iCloud)
        let appPermissions = missingFirst([AppPermission.fullDiskAccess, .iCloud]) { permission in
            switch permission {
            case .fullDiskAccess: return fullDiskAccess
            case .iCloud: return iCloudAccount
            }
        }
        let configs = missingFirst(permissionConfigs, status: serviceStatus)
        Form {
            Section {
                ForEach(appPermissions, id: \.self) { permission in
                    switch permission {
                    case .fullDiskAccess:
                        PermissionRow(
                            systemName: "internaldrive.fill",
                            color: .gray,
                            title: "Full Disk Access",
                            status: fullDiskAccess
                        ) {
                            PermissionDetail(
                                text: FullDiskAccessStatus.explanation(
                                    requiredBy: status.fullDiskAccessNeededBy,
                                    needsOwner: fullDiskAccess.needsOwner
                                )
                            )
                        } actions: {
                            if fullDiskAccess.needsOwner {
                                Button("Grant…") {
                                    guidance.openFullDiskAccessSettings()
                                }
                            }
                        }
                    case .iCloud:
                        ICloudAccountRow(
                            session: iCloud,
                            report: status.iCloud,
                            status: iCloudAccount,
                            showSignIn: guidance.showICloudSignIn
                        )
                    }
                }
            } header: {
                HStack {
                    Text("App Permissions")
                    Spacer()
                    Button("Refresh") {
                        appStatus.refresh()
                    }
                    .buttonStyle(.borderless)
                }
            }

            Section("Service Permissions") {
                ForEach(configs) { config in
                    ServicePermissionRow(
                        config: config,
                        status: serviceStatus(config),
                        grant: { Task { await guidance.grantAccess(to: config) } }
                    )
                }
            }
        }
        .formStyle(.grouped)
        .motion(.surface, value: appPermissions)
        .motion(.surface, value: configs.map(\.id))
        .onAppear { appStatus.refresh() }
    }
}

/// iCloud sits with Full Disk Access rather than with the services: it is one
/// account for the whole app, and the Location service's own row reports what
/// that account buys it.
private struct ICloudAccountRow: View {
    let session: ICloudSession
    /// The same report the menu's row comes from.
    let report: ICloudStatus.Report
    let status: ServicePermissionStatus
    let showSignIn: @MainActor () -> Void

    var body: some View {
        PermissionRow(systemName: "icloud.fill", color: .blue, title: "iCloud Account", status: status) {
            PermissionDetail(text: report.summary.detail)
            if let note = report.note {
                StatusNote(level: .attention, text: note)
            }
        } actions: {
            if report.offersSignInAgain {
                Button("Sign In Again…") {
                    session.beginManualSignIn()
                    showSignIn()
                }
            }

            if report.isSignedIn {
                ICloudSignOutButton(session: session)
            } else {
                Button("Sign In…") {
                    showSignIn()
                }
            }
        }
    }
}

private struct ServicePermissionRow: View {
    let config: ServiceSwitch
    /// Read by the parent from the switch and `AppStatus.serviceAccess`; see
    /// `PermissionsSettingsView.body`.
    let status: ServicePermissionStatus
    let grant: () -> Void

    var body: some View {
        PermissionRow(
            systemName: ServicePresentation.of(config.id).iconName,
            color: ServicePresentation.of(config.id).color,
            title: config.name,
            status: status
        ) {
            if status.needsOwner, let detail = config.permission.settingsDetail {
                PermissionDetail(text: detail)
                    .transition(.opacity)
            }
        } actions: {
            if status.needsOwner {
                Button("Grant…", action: grant)
            }
        }
    }
}

/// One permission: what it is, whether iMCP has it, and, only while something
/// is missing, what to do about it.
private struct PermissionRow<Details: View, Actions: View>: View {
    let systemName: String
    let color: Color
    let title: String
    let status: ServicePermissionStatus
    @ViewBuilder var details: Details
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            SettingsIcon(systemName: systemName, color: color)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(title)
                details
            }

            Spacer(minLength: DesignTokens.Spacing.md)

            PermissionStatusLabel(status: status)

            actions
                .glassButtonStyle()
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
        .motion(.surface, value: status)
    }
}

private struct PermissionDetail: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DesignTokens.Typography.detail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The answer in a word, with an icon whose shape says the same. Granted is
/// the quiet one: only its tick is coloured.
private struct PermissionStatusLabel: View {
    let status: ServicePermissionStatus

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(status.needsOwner ? .primary : .secondary)
        } icon: {
            Image(systemName: symbolName)
                .foregroundStyle(symbolColor)
        }
        .labelStyle(.titleAndIcon)
        .font(DesignTokens.Typography.detail)
        .fixedSize()
    }

    private var title: String {
        switch status {
        case .granted: return "Granted"
        case .notGranted: return "Not granted"
        case .notEnabled: return "Not enabled"
        case .checking: return "Checking…"
        }
    }

    private var symbolName: String {
        switch status {
        case .granted: return StatusSummary.Level.ok.symbolName
        case .notGranted: return StatusSummary.Level.attention.symbolName
        case .notEnabled: return "minus.circle"
        case .checking: return "ellipsis.circle"
        }
    }

    private var symbolColor: Color {
        switch status {
        case .granted: return StatusSummary.Level.ok.color
        case .notGranted: return StatusSummary.Level.attention.color
        case .notEnabled, .checking: return .secondary
        }
    }
}

struct GeneralSettingsView: View {
    @AppStorage(PreferenceKey.showMenuBarExtra) private var showMenuBarExtra = PreferenceKey.showMenuBarExtraDefault
    var isMenuBarExtraInserted: Bool
    @StateObject private var loginItems = LoginItemsModel()

    var body: some View {
        Form {
            Section("Menu Bar") {
                Toggle(isOn: $showMenuBarExtra) {
                    Text("Show in Menu Bar")
                    Text("If the icon is hidden, open iMCP again to return to Settings.")
                }

                if showMenuBarExtra && !isMenuBarExtraInserted {
                    StatusNote(
                        level: .attention,
                        text: "macOS hid the menu bar icon. Check System Settings > Menu Bar, "
                            + "or turn this off and on again."
                    )
                }
            }

            Section("Startup") {
                Toggle(isOn: $loginItems.launchAtLogin) {
                    Text("Launch at Login")
                    Text(
                        loginItems.alwaysOn
                            ? "Included with Always Keep iMCP Running."
                            : "Start iMCP automatically after you log in, so MCP clients can connect without opening the app first."
                    )
                }
                .disabled(loginItems.alwaysOn)

                if let error = loginItems.error {
                    StatusNote(level: .problem, text: error)
                }

                if loginItems.approvalNeeded {
                    StatusNote(
                        level: .problem,
                        text: "Approval needed: enable iMCP under System Settings → General → Login Items."
                    )
                }

                Toggle(isOn: $loginItems.alwaysOn) {
                    Text("Always Keep iMCP Running")
                    Text("Relaunch iMCP automatically whenever it quits. This also starts iMCP at login.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: DesignTokens.Spacing.lg) {
                    AppIconImage(size: DesignTokens.Size.settingsHeroIcon)
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                        Text("iMCP")
                            .font(.headline)
                        Text("Version \(Bundle.main.shortVersionString ?? "")")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, DesignTokens.Spacing.xs)
            }

            Section {
                ExternalLinkRow(title: "Source on GitHub", url: AppLinks.repository)
                ExternalLinkRow(title: "Report an Issue…", url: AppLinks.newIssue)
            } footer: {
                if let copyright = Bundle.main.copyright {
                    SettingsCaption(copyright)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ClientsSettingsView: View {
    @ObservedObject var pairedClientStore: PairedClientStore
    let showConnectClient: @MainActor () -> Void
    @State private var unpairRequest: UnpairRequest?

    var body: some View {
        let pairedClients = pairedClientStore.clients ?? []
        let summary = ClientsStatus.summary(pairedCount: pairedClientStore.clients?.count)
        Form {
            Section {
                if summary.level != .ok {
                    StatusNote(level: summary.level, text: summary.detail)
                        .padding(.vertical, DesignTokens.Spacing.xs)
                } else if pairedClients.isEmpty {
                    EmptyStateCard(
                        systemName: "app.connected.to.app.below.fill",
                        title: "No Paired Clients",
                        detail: ClientsStatus.noneYet
                    )
                    .transition(.opacity)
                } else {
                    ForEach(pairedClients, id: \.fingerprint) { client in
                        clientRow(client)
                            .transition(.reveal())
                    }
                }
            } header: {
                HStack {
                    Text("Paired Clients")
                    Spacer()
                    if !pairedClients.isEmpty {
                        Button("Unpair All") {
                            unpairRequest = .all
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(DesignTokens.StatusColor.problem)
                    }
                }
            } footer: {
                SettingsCaption("Paired agents connect without asking.")
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                        Text("Connect a Client")
                        Text("Set up Claude, Codex, or another MCP client to use iMCP.")
                            .font(DesignTokens.Typography.detail)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Connect…") {
                        showConnectClient()
                    }
                    .glassProminentButtonStyle()
                }
            }
        }
        .formStyle(.grouped)
        .motion(.surface, value: pairedClients.map(\.fingerprint))
        .task { await pairedClientStore.reload() }
        .alert(
            unpairRequest?.title ?? "",
            isPresented: Binding(
                get: { unpairRequest != nil },
                set: { if !$0 { unpairRequest = nil } }
            ),
            presenting: unpairRequest
        ) { request in
            Button("Cancel", role: .cancel) {}
            Button(request.confirmLabel, role: .destructive) {
                unpair(request)
            }
        } message: { request in
            Text(request.message)
        }
    }

    private func clientRow(_ client: PairedClient) -> some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            SettingsIcon(systemName: "terminal.fill", color: .gray)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(client.label.isEmpty ? "Unnamed client" : client.label)
                Text(
                    PairedClient.shortFingerprint(client.fingerprint) + " · paired "
                        + client.addedAt.formatted(date: .abbreviated, time: .shortened)
                )
                .font(DesignTokens.Typography.detail)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Unpair…") {
                unpairRequest = .clients([client])
            }
            .glassButtonStyle()
        }
        .contextMenu {
            Button("Unpair", role: .destructive) {
                unpairRequest = .clients([client])
            }
        }
    }

    private func unpair(_ request: UnpairRequest) {
        guard let fingerprints = request.fingerprints else {
            Task { await pairedClientStore.reset() }
            return
        }
        Task {
            for fingerprint in fingerprints {
                await pairedClientStore.remove(fingerprint: fingerprint)
            }
        }
    }
}
