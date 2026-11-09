import Combine
import Foundation

struct PairingOutcome: Equatable, Sendable {
    enum Route: Equatable, Sendable {
        case pairingCode
        /// The person ticked "Always allow" on the approval prompt.
        case approval
    }

    let fingerprint: String
    /// The client now paired, or nil when it was paired already or the store
    /// could not save it.
    let client: PairedClient?
    let route: Route
}

/// The app's one way to read and change the paired clients. Every write
/// goes through here, so the published list follows them all.
@MainActor
final class PairedClientStore: ObservableObject {
    private let storage: PairedClientStorage

    /// Newest first. nil when the store could not be read. Empty until the
    /// first read lands. A cache for the views only: `contains` still asks
    /// `storage` every time.
    @Published private(set) var clients: [PairedClient]? = []
    private var reloadsStarted = 0
    private var newestLanded = 0
    /// The latest pairing's reload and outcome; each waits for the one before.
    private var refresh: Task<Void, Never>?

    /// One for every `pair`, in order, after the list has been reloaded.
    let pairingOutcomes = PassthroughSubject<PairingOutcome, Never>()

    init(storage: PairedClientStorage) {
        self.storage = storage
        Task { [weak self] in await self?.reload() }
    }

    /// A read that comes back after a later one has landed is dropped, so a
    /// slow read cannot put back a list the later one replaced.
    func reload() async {
        reloadsStarted += 1
        let reload = reloadsStarted
        let loaded = await storage.all()
        guard reload > newestLanded else { return }
        newestLanded = reload
        clients = loaded?.sorted { $0.addedAt > $1.addedAt }
    }

    /// False, too, when the list could not be read within `deadline`.
    nonisolated func contains(
        fingerprint: String,
        within deadline: Duration = KeychainItemQueue.promptDeadline
    ) async -> Bool {
        await storage.contains(fingerprint: fingerprint, within: deadline)
    }

    /// Returns once the client is saved, or could not be. The list the views
    /// read, and then `pairingOutcomes`, follow once it is reloaded, so a
    /// caller does not wait on that second read.
    func pair(_ client: PairedClient, route: PairingOutcome.Route) async {
        let paired = await storage.add(client) ? client : nil
        let outcome = PairingOutcome(fingerprint: client.fingerprint, client: paired, route: route)
        let previous = refresh
        refresh = Task { [weak self] in
            await previous?.value
            await self?.reload()
            self?.pairingOutcomes.send(outcome)
        }
    }

    /// Returns once every pairing's reload and outcome has landed.
    func settle() async {
        while let pending = refresh {
            await pending.value
            if refresh == pending { refresh = nil }
        }
    }

    func remove(fingerprint: String) async {
        await storage.remove(fingerprint: fingerprint)
        await reload()
    }

    func reset() async {
        await storage.reset()
        await reload()
    }
}
