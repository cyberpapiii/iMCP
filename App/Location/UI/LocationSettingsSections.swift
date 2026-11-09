import AppKit
import SwiftUI

/// The Location page of Settings: Find My People setup and the recorded
/// history.
struct LocationSettingsSections: View {
    let locationEnabled: Bool
    let lifecycle: LocationDataLifecycle

    var body: some View {
        LocationHistorySection(lifecycle: lifecycle)

        FindMyPeopleSettingsSection(locationEnabled: locationEnabled, lifecycle: lifecycle)
    }
}

func findMyPeopleStatusText(
    state: FindMyPeopleBootstrapState,
    peopleEnabled: Bool,
    health: FindMyPeopleHealth
) -> String {
    switch state {
    case .notConfigured: return "Not set up. Open the Setup Guide to start."
    case .keychainUnavailable: return "The setup state could not be read from the Keychain. Try again later."
    case .handoffReady: return "Handoff ready. Follow the guide for the user-run capture."
    case .restorationRequired: return "Envelope captured. Restore security, reboot, and verify."
    case .envelopeReady: return "Restoration report ready. Authenticate to import once."
    case .configured:
        let configured = peopleEnabled ? "Ready and enabled." : "Configured, but People access is off."
        if let lastSuccess = health.lastSuccess, let rowCount = health.rowCount {
            return
                "\(configured) Last local read \(lastSuccess.formatted(date: .omitted, time: .shortened)); \(rowCount) rows."
        }
        if let category = health.lastErrorCategory { return "\(configured) Last read: \(category)." }
        return configured
    }
}

private struct FindMyPeopleSettingsSection: View {
    let locationEnabled: Bool
    let lifecycle: LocationDataLifecycle
    @State private var peopleEnabled = false
    @State private var bootstrapState: FindMyPeopleBootstrapState = .notConfigured
    @State private var health = FindMyPeopleHealth(lastSuccess: nil, rowCount: nil, lastErrorCategory: nil)
    @State private var message: String?
    /// What is running now, in words for the spinner; nil when nothing is.
    @State private var activity: String?
    @State private var showingPurgeAlert = false
    @State private var peopleMutationTask: Task<Void, Never>?

    private var working: Bool { activity != nil }

    var body: some View {
        Section {
            HStack {
                Text(findMyPeopleStatusText(state: bootstrapState, peopleEnabled: peopleEnabled, health: health))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DesignTokens.Spacing.md)
                if let activity {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        ProgressView()
                            .controlSize(.small)
                        Text(activity)
                            .font(DesignTokens.Typography.detail)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .transition(.opacity)
                }
                setupActions
                    .glassButtonStyle()
            }
            .motion(.quick, value: activity)

            if let message {
                StatusNote(level: .attention, text: message)
            }

            Toggle(isOn: $peopleEnabled) {
                Text("Allow approved MCP clients to read Find My People")
                Text(
                    locationEnabled
                        ? "When on, every approved agent can see where your friends are and have been."
                        : "Location is off, so no agent can see your friends. Your choice here is kept."
                )
            }
            .disabled(!locationEnabled || bootstrapState != .configured || working)
            .onChange(of: peopleEnabled) { _, enabled in
                peopleMutationTask?.cancel()
                peopleMutationTask = Task { @MainActor in
                    guard !Task.isCancelled else { return }
                    await lifecycle.setPeopleEnabled(enabled)
                }
            }

            ExternalLinkRow(title: "Setup Guide", url: AppLinks.findMyPeopleSetupGuide)
        } header: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text("Find My People")
                Text("Advanced")
                    .font(DesignTokens.Typography.detail)
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .padding(.vertical, DesignTokens.Spacing.hairline)
                    .background(.quaternary, in: Capsule())
                Spacer()
                Button("Refresh") { Task { await refresh() } }
                    .buttonStyle(.borderless)
            }
        }
        .task { await refresh() }
        .disabled(working)
        .alert("Remove Find My People?", isPresented: $showingPurgeAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Key Only", role: .destructive) {
                run("Clearing the key…") { try await lifecycle.clearKeyOnly() }
            }
            Button("Purge Everything", role: .destructive) {
                run("Removing Find My People…") { try await lifecycle.purgeEverything() }
            }
        } message: {
            Text(
                "Clear Key Only removes the imported key and turns People off. Using People again needs a new capture. Purge Everything also deletes the installation identity, pending setup and recorded friend locations. Device history and named places are kept."
            )
        }
    }

    /// The next step of setup, or Remove once it is done.
    @ViewBuilder
    private var setupActions: some View {
        switch bootstrapState {
        case .notConfigured:
            Button("Prepare Setup") { run("Preparing setup…") { try await prepare() } }
        case .keychainUnavailable:
            EmptyView()
        case .handoffReady, .restorationRequired:
            Button("Show Setup Folder") { showSetupFolder() }
        case .envelopeReady:
            Button("Import Encrypted Key") {
                run("Importing the key…") { try await lifecycle.importKey() }
            }
        case .configured:
            Button("Remove…", role: .destructive) {
                showingPurgeAlert = true
            }
        }
        if [.handoffReady, .restorationRequired, .envelopeReady].contains(bootstrapState) {
            Button("Cancel Setup", role: .destructive) {
                run("Cancelling setup…") { try await lifecycle.cancelSetup() }
            }
        }
    }

    private func run(_ activity: String, _ operation: @escaping @MainActor () async throws -> Void) {
        self.activity = activity
        message = nil
        Task {
            do {
                try await operation()
            } catch {
                message = sanitizedToolErrorMessage(
                    for: error,
                    fallback: "The Find My People setup action could not be completed."
                )
            }
            self.activity = nil
            await refresh()
        }
    }

    private func prepare() async throws {
        let url = try await lifecycle.prepareSetup()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func showSetupFolder() {
        NSWorkspace.shared.open(lifecycle.setupFolder)
    }

    private func refresh() async {
        let status = await lifecycle.peopleStatus()
        bootstrapState = status.setup
        peopleEnabled = status.enabled
        health = status.health
    }
}

/// What the Location sampler has collected, and the two things a user might
/// want to do about it: look at the file, or throw the recordings away.
private struct LocationHistorySection: View {
    let lifecycle: LocationDataLifecycle
    @State private var summary: LocationHistorySummary?
    @State private var loadFailure: String?
    @State private var deleteFailure: String?
    @State private var showingDeleteAlert = false
    @State private var showingDeletePeopleAlert = false

    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                if let failure = deleteFailure ?? loadFailure {
                    StatusNote(level: .problem, text: failure)
                } else {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                        Text(headline)
                            .foregroundStyle(summary?.sampleCount ?? 0 > 0 ? .primary : .secondary)
                        Text(subline)
                            .font(DesignTokens.Typography.detail)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                }
                Spacer(minLength: DesignTokens.Spacing.md)
                Button("Show in Finder") {
                    Task { await lifecycle.revealFile() }
                }
                .glassButtonStyle()
            }
        } header: {
            HStack {
                Text("Location History")
                Spacer()
                if summary?.sampleCount ?? 0 > 0 {
                    Button("Delete History…") {
                        showingDeleteAlert = true
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(DesignTokens.StatusColor.problem)
                }
                if summary?.peopleSampleCount ?? 0 > 0 {
                    Button("Delete Friend History…") {
                        showingDeletePeopleAlert = true
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(DesignTokens.StatusColor.problem)
                }
            }
        } footer: {
            SettingsCaption(
                "iMCP records enabled device and Find My People positions while it runs, on this Mac only. Apple keeps no history of its own."
            )
        }
        .task {
            await load()
            for await _ in await lifecycle.changes() {
                await load()
            }
        }
        .alert("Delete Location History?", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete History", role: .destructive) {
                delete { try await lifecycle.deleteHistory() }
            }
        } message: {
            Text(
                "This removes every recorded position. Your named places are kept, and recording continues while you are signed in."
            )
        }
        .alert("Delete Friend History?", isPresented: $showingDeletePeopleAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Friend History", role: .destructive) {
                delete { try await lifecycle.deleteFriendHistory() }
            }
        } message: {
            Text(
                "This removes recorded Find My People positions only. Device history and named places are kept."
            )
        }
    }

    /// How much is recorded and since when.
    private var headline: String {
        guard let summary else { return "Reading…" }
        guard summary.sampleCount > 0 else { return "No positions recorded yet" }
        let count = summary.sampleCount == 1 ? "1 position" : "\(summary.sampleCount.formatted()) positions"
        guard let oldest = summary.oldest else { return count }
        return "\(count) since \(oldest.formatted(date: .abbreviated, time: .omitted))"
    }

    /// What else the history holds: friends' positions and named places.
    private var subline: String {
        guard let summary else { return " " }
        var parts: [String] = []
        switch summary.peopleSampleCount {
        case 0: break
        case 1: parts.append("1 friend position")
        default: parts.append("\(summary.peopleSampleCount.formatted()) friend positions")
        }
        parts.append(summary.placeCount == 1 ? "1 named place" : "\(summary.placeCount) named places")
        return parts.joined(separator: " · ")
    }

    /// A delete reloads through `changes()`. A failed one keeps its error on
    /// screen until the next delete: the reload it may still trigger must
    /// not wipe the reason.
    private func delete(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            deleteFailure = nil
            do {
                try await operation()
            } catch {
                deleteFailure = error.localizedDescription
            }
        }
    }

    private func load() async {
        do {
            summary = try await lifecycle.summary()
            loadFailure = nil
        } catch {
            loadFailure = error.localizedDescription
        }
    }
}
