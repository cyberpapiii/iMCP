import Foundation
import Security
import os

/// The paired clients, persisted in the Keychain so a same-user `defaults
/// write` cannot inject a fingerprint. Every method re-reads before acting.
/// There is no cached array. The app writes only through `PairedClientStore`.
///
/// A read waits on the Keychain at most `KeychainItemQueue.promptDeadline`
/// and is otherwise
/// unavailable, like every other secret the app reads: a build that falls
/// back to the file keychain can get an authorization prompt for this item,
/// and nobody may wait on that unbounded. A write reads the definitive list
/// first, and fails when it has not finished within the same deadline.
struct PairedClientStorage: Sendable {
    /// Where builds before the Keychain kept the list. Read only to migrate it.
    static let storageKey = "pairedClients"
    static let keychainService = "co.dododo.iMCP.paired-clients"

    /// Reads and read-modify-writes of this item, one at a time.
    private let item: KeychainItemQueue<[PairedClient]>

    /// Production uses `production`, the one storage over the real item.
    init(calls: KeychainItemCalls) {
        self.item = KeychainItemQueue(label: Self.keychainService, json: calls)
    }

    enum UserDefaultsMigration: Equatable {
        case skippedEmpty
        case skippedKeychainWriteFailed
        case completed
    }

    /// The one storage over the Keychain item, so every caller shares its
    /// queue. Migrates a leftover UserDefaults list once, before the first
    /// read or write, on whichever call does that first: the migration reads
    /// the Keychain too.
    static let production: PairedClientStorage = {
        let item = KeychainItem(service: keychainService)
        let migrated = OSAllocatedUnfairLock(initialState: false)
        let migrateOnce: @Sendable () -> Void = {
            migrated.withLock { done in
                guard !done else { return }
                done = true
                migrate(item)
            }
        }
        return PairedClientStorage(
            calls: KeychainItemCalls(
                load: {
                    migrateOnce()
                    return item.load()
                },
                save: {
                    migrateOnce()
                    return item.save($0)
                },
                delete: { item.delete() }
            )
        )
    }()

    private static func migrate(_ item: KeychainItem) {
        let load: () -> KeychainItem.LoadResult = { item.load() }
        let save: (Data) -> Bool = { item.save($0) }
        #if DEBUG
            let marker = KeychainItem(service: debugFileAdoptedService)
            adoptDebugFileOnce(
                markerLoad: { marker.load() },
                mark: { marker.save(Data([1])) },
                fileRead: { SecretFileStore.read(secretFileName) },
                fileDelete: { SecretFileStore.delete(secretFileName) },
                keychainSave: save,
                keychainLoad: load
            )
        #endif
        _ = migrateUserDefaultsIfNeeded(
            defaults: .standard,
            keychainLoad: load,
            keychainSave: save
        )
    }

    #if DEBUG
        private static let secretFileName = "paired-clients.json"
        static let debugFileAdoptedService = keychainService + ".debug-file-adopted"

        /// Debug builds before plan 043 kept the paired list in a plain file.
        /// This moves it into the Keychain once. The file wins over whatever
        /// the Keychain holds, because it was the live store. Nothing is
        /// marked or deleted until the Keychain reads back the same bytes, so
        /// a failed copy leaves the file for the next launch. After that
        /// either the marker or the missing file stops a stale file from
        /// overwriting the live list. Returns true when a list was adopted.
        @discardableResult
        static func adoptDebugFileOnce(
            markerLoad: () -> KeychainItem.LoadResult,
            mark: () -> Bool,
            fileRead: () -> SecretFileStore.Read,
            fileDelete: () -> Bool,
            keychainSave: (Data) -> Bool,
            keychainLoad: () -> KeychainItem.LoadResult
        ) -> Bool {
            // `.data` means done; `.failed` means the Keychain is unreadable
            // right now, and adopting blind could repeat on every launch.
            guard markerLoad() == .missing else { return false }
            switch fileRead() {
            case .failed:
                return false
            case .missing:
                _ = mark()
                return false
            case .data(let data):
                guard (try? JSONDecoder().decode([PairedClient].self, from: data)) != nil,
                    keychainSave(data), keychainLoad() == .data(data)
                else { return false }
                // Both are attempted. Accepted: if both fail, the next launch adopts the file again.
                _ = mark()
                _ = fileDelete()
                return true
            }
        }
    #endif

    /// nil when the store could not be read in time, which is not the same
    /// as empty.
    func all(within deadline: Duration = KeychainItemQueue.promptDeadline) async -> [PairedClient]? {
        switch await item.load(within: deadline) {
        case .found(let clients): return clients
        case .missing: return []
        case .unavailable: return nil
        }
    }

    /// False when the store could not be read in time: the client is then
    /// asked about, as an unpaired one is.
    func contains(fingerprint: String, within deadline: Duration = KeychainItemQueue.promptDeadline) async -> Bool {
        await all(within: deadline)?.contains { $0.fingerprint == fingerprint } ?? false
    }

    /// True when the client was not paired before and is now saved.
    func add(_ client: PairedClient, within deadline: Duration = KeychainItemQueue.promptDeadline) async -> Bool {
        await write(within: deadline) { clients in
            guard !clients.contains(where: { $0.fingerprint == client.fingerprint }) else { return nil }
            return clients + [client]
        }
    }

    func remove(fingerprint: String) async {
        _ = await write { clients in
            let kept = clients.filter { $0.fingerprint != fingerprint }
            return kept.count == clients.count ? nil : kept
        }
    }

    func reset() async {
        _ = await write { clients in clients.isEmpty ? nil : [] }
    }

    /// Reads the definitive list and saves what `change` makes of it; nil
    /// leaves it as it is. Nothing is saved over a list that could not be
    /// read. True when a changed list was saved; false, too, when the write
    /// had not finished within `deadline`.
    private func write(
        within deadline: Duration = KeychainItemQueue.promptDeadline,
        _ change: @escaping @Sendable ([PairedClient]) -> [PairedClient]?
    ) async -> Bool {
        let saved = await item.run(within: deadline) { item in
            let clients: [PairedClient]
            switch item.read() {
            case .found(let found): clients = found
            case .missing: clients = []
            case .unavailable: return false
            }
            guard let changed = change(clients) else { return false }
            return item.save(changed)
        }
        return saved ?? false
    }

    /// Copies UserDefaults into the Keychain, then deletes the defaults copy
    /// only after the Keychain read-back matches. A failed write must leave
    /// the list in UserDefaults so the next launch can retry.
    ///
    /// Only `.missing` is empty. A `.failed` load must not save or delete.
    /// Missing plus empty defaults writes encoded `[]` so a later defaults
    /// write cannot migrate in.
    static func migrateUserDefaultsIfNeeded(
        defaults: UserDefaults,
        keychainLoad: () -> KeychainItem.LoadResult,
        keychainSave: (Data) -> Bool
    ) -> UserDefaultsMigration {
        switch keychainLoad() {
        case .failed:
            return .skippedKeychainWriteFailed
        case .data:
            if defaults.data(forKey: storageKey) != nil {
                defaults.removeObject(forKey: storageKey)
                return .completed
            }
            return .skippedEmpty
        case .missing:
            break
        }

        if let data = defaults.data(forKey: storageKey), !data.isEmpty {
            guard keychainSave(data), keychainLoad() == .data(data) else {
                return .skippedKeychainWriteFailed
            }
            defaults.removeObject(forKey: storageKey)
            return .completed
        }

        let emptySentinel: Data
        do {
            emptySentinel = try JSONEncoder().encode([PairedClient]())
        } catch {
            assertionFailure("Failed to encode empty paired-client sentinel: \(error)")
            return .skippedKeychainWriteFailed
        }
        guard keychainSave(emptySentinel), keychainLoad() == .data(emptySentinel) else {
            return .skippedKeychainWriteFailed
        }
        return .skippedEmpty
    }
}
