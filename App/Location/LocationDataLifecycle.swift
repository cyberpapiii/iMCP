import AppKit
import Foundation

/// What Settings can do to Location's stored data: the recorded history and
/// the Find My People setup. Every destructive step and its error lives
/// here, so the view only shows progress and words.
struct LocationDataLifecycle: Sendable {
    let history: LocationHistoryStore
    let readiness: FindMyPeopleReadiness
    let bootstrap: FindMyPeopleBootstrap

    // MARK: - Recorded history

    func summary() async throws -> LocationHistorySummary {
        try await history.summary()
    }

    func changes() async -> AsyncStream<Void> {
        await history.changes()
    }

    /// Every recorded position. Named places are kept.
    func deleteHistory() async throws {
        try await history.deleteSamples()
    }

    /// Recorded Find My People positions only. Device history and named
    /// places are kept.
    func deleteFriendHistory() async throws {
        try await history.deletePeopleSamples()
    }

    @MainActor
    func revealFile() async {
        NSWorkspace.shared.activateFileViewerSelecting([await history.fileURL])
    }

    // MARK: - Find My People

    struct PeopleStatus: Equatable, Sendable {
        var setup: FindMyPeopleBootstrapState
        var enabled: Bool
        var health: FindMyPeopleHealth
    }

    func peopleStatus() async -> PeopleStatus {
        PeopleStatus(
            setup: await bootstrap.state(),
            enabled: await readiness.isPeopleEnabled(),
            health: await readiness.health()
        )
    }

    func setPeopleEnabled(_ enabled: Bool) async {
        await readiness.setPeopleEnabled(enabled)
    }

    /// The handoff file the user-run capture reads.
    func prepareSetup() async throws -> URL {
        try await bootstrap.prepare()
    }

    var setupFolder: URL { FindMyPeopleBootstrap.artifactDirectory }

    func importKey() async throws {
        try await bootstrap.importPreparedEnvelope()
    }

    func cancelSetup() async throws {
        try await bootstrap.clearPreparedHandoff()
    }

    /// Turns People off and deletes the imported key; using People again
    /// needs a new capture.
    func clearKeyOnly() async throws {
        try await readiness.clearDatabaseKey()
    }

    /// Turns People off, then deletes friend history, both secrets, and any
    /// pending setup. Device history and named places are kept, including
    /// places named from a friend's position: they stay hidden while People
    /// is off.
    func purgeEverything() async throws {
        let history = history
        let bootstrap = bootstrap
        try await Self.purge(
            readiness: readiness,
            deletePeopleHistory: { try await history.deletePeopleSamples() },
            clearPreparedHandoff: { try await bootstrap.clearPreparedHandoff() }
        )
    }

    /// Revocation first, then friend history, then the secrets, then the
    /// pending setup. Any partial deletion keeps the gate off and reports
    /// exactly which deletion failed; the secrets are reported first because
    /// they matter most.
    static func purge(
        readiness: FindMyPeopleReadiness,
        deletePeopleHistory: @Sendable () async throws -> Void,
        clearPreparedHandoff: @Sendable () async throws -> Void
    ) async throws {
        await readiness.revokeAndQuiesce()
        do {
            try await deletePeopleHistory()
        } catch {
            throw FindMyPeopleLifecycleError.historyPurgeFailed
        }
        let cleared = await readiness.clearSecrets()
        let setupCleared = (try? await clearPreparedHandoff()) != nil
        guard cleared.databaseKeyCleared && cleared.identitySecretCleared else {
            throw FindMyPeopleLifecycleError.secretPurgeFailed(
                databaseKeyCleared: cleared.databaseKeyCleared,
                identitySecretCleared: cleared.identitySecretCleared
            )
        }
        guard setupCleared else { throw FindMyPeopleLifecycleError.setupPurgeFailed }
    }
}
