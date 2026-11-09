import Combine
@testable import iMCP
import Security
import XCTest

@MainActor
final class PairedClientStoreTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private var keychain: InMemoryKeychainItem!
    private var store: PairedClientStore!

    private let fingerprintA = "aa" + String(repeating: "0", count: 62)
    private let fingerprintB = "bb" + String(repeating: "0", count: 62)

    override func setUp() {
        super.setUp()
        userDefaults = makeTemporaryDefaults()
        keychain = InMemoryKeychainItem()
        store = PairedClientStore(storage: keychain.pairedClientStorage)
    }

    override func tearDown() {
        store = nil
        keychain = nil
        userDefaults = nil
        super.tearDown()
    }

    private func outcomes(of store: PairedClientStore) -> (AnyCancellable, () -> [PairingOutcome]) {
        var collected: [PairingOutcome] = []
        let subscription = store.pairingOutcomes.sink { collected.append($0) }
        return (subscription, { collected })
    }

    func testAddAndContainsRoundTripThroughJSONEncoding() async throws {
        let addedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let client = PairedClient(fingerprint: fingerprintA, label: "Test Client", addedAt: addedAt)

        await store.pair(client, route: .approval)
        await store.settle()

        let contains = await store.contains(fingerprint: fingerprintA)
        XCTAssertTrue(contains)
        XCTAssertEqual(store.clients, [client])

        let rawData = try XCTUnwrap(keychain.data)
        let decoded = try JSONDecoder().decode([PairedClient].self, from: rawData)
        XCTAssertEqual(decoded, [client])
    }

    /// Fingerprint is identity: a second add must not duplicate the row or
    /// overwrite the original label and date.
    func testAddIsIdempotentByFingerprint() async {
        let first = PairedClient(
            fingerprint: fingerprintA,
            label: "First Label",
            addedAt: Date(timeIntervalSince1970: 100)
        )
        let duplicate = PairedClient(
            fingerprint: fingerprintA,
            label: "Second Label",
            addedAt: Date(timeIntervalSince1970: 200)
        )

        await store.pair(first, route: .approval)
        await store.pair(duplicate, route: .approval)
        await store.settle()

        XCTAssertEqual(store.clients?.count, 1)
        XCTAssertEqual(store.clients?.first?.label, "First Label")
    }

    /// Every pairing reports what became of it, and only a client not paired
    /// before counts as newly paired.
    func testOnlyAClientNotSeenBeforeCountsAsNewlyPaired() async {
        let a = PairedClient(fingerprint: fingerprintA, label: "A", addedAt: Date(timeIntervalSince1970: 100))
        let b = PairedClient(fingerprint: fingerprintB, label: "B", addedAt: Date(timeIntervalSince1970: 200))
        let relabelled = PairedClient(fingerprint: fingerprintA, label: "A again", addedAt: Date())
        let (subscription, outcomes) = outcomes(of: store)
        defer { subscription.cancel() }

        await store.pair(a, route: .approval)
        await store.pair(b, route: .approval)
        await store.pair(a, route: .approval)
        await store.pair(relabelled, route: .approval)
        await store.settle()

        XCTAssertEqual(
            outcomes(),
            [
                PairingOutcome(fingerprint: fingerprintA, client: a, route: .approval),
                PairingOutcome(fingerprint: fingerprintB, client: b, route: .approval),
                PairingOutcome(fingerprint: fingerprintA, client: nil, route: .approval),
                PairingOutcome(fingerprint: fingerprintA, client: nil, route: .approval),
            ]
        )
        XCTAssertEqual(store.clients, [b, a])

        let unreadable = PairedClientStore(
            storage: InMemoryKeychainItem(loadFailure: errSecInteractionNotAllowed).pairedClientStorage
        )
        let (unreadableSubscription, unreadableOutcomes) = self.outcomes(of: unreadable)
        defer { unreadableSubscription.cancel() }
        await unreadable.pair(a, route: .approval)
        await unreadable.settle()
        XCTAssertEqual(
            unreadableOutcomes(),
            [PairingOutcome(fingerprint: fingerprintA, client: nil, route: .approval)],
            "A list that could not be read gains nobody"
        )
    }

    func testAClientPairedBeforeThisLaunchIsNotNew() async {
        let first = PairedClient(fingerprint: fingerprintA, label: "A", addedAt: Date(timeIntervalSince1970: 100))
        let again = PairedClient(fingerprint: fingerprintA, label: "A", addedAt: Date(timeIntervalSince1970: 200))
        await store.pair(first, route: .approval)
        await store.settle()

        let relaunched = PairedClientStore(storage: keychain.pairedClientStorage)
        await relaunched.reload()
        XCTAssertEqual(relaunched.clients, [first])
        let (subscription, outcomes) = outcomes(of: relaunched)
        defer { subscription.cancel() }
        await relaunched.pair(again, route: .approval)
        await relaunched.settle()
        XCTAssertEqual(outcomes().map(\.client), [nil])
    }

    func testRemove() async {
        await store.pair(PairedClient(fingerprint: fingerprintA, label: "A", addedAt: Date()), route: .approval)
        await store.pair(PairedClient(fingerprint: fingerprintB, label: "B", addedAt: Date()), route: .approval)
        await store.settle()

        await store.remove(fingerprint: fingerprintA)

        let containsA = await store.contains(fingerprint: fingerprintA)
        let containsB = await store.contains(fingerprint: fingerprintB)
        XCTAssertFalse(containsA)
        XCTAssertTrue(containsB)
        XCTAssertEqual(store.clients?.count, 1)
    }

    func testReset() async throws {
        await store.pair(PairedClient(fingerprint: fingerprintA, label: "A", addedAt: Date()), route: .approval)
        await store.pair(PairedClient(fingerprint: fingerprintB, label: "B", addedAt: Date()), route: .approval)
        await store.settle()

        await store.reset()

        XCTAssertEqual(store.clients, [])
        let containsA = await store.contains(fingerprint: fingerprintA)
        let containsB = await store.contains(fingerprint: fingerprintB)
        XCTAssertFalse(containsA)
        XCTAssertFalse(containsB)

        let rawData = try XCTUnwrap(keychain.data)
        let decoded = try JSONDecoder().decode([PairedClient].self, from: rawData)
        XCTAssertTrue(decoded.isEmpty)
    }

    func testClientsSortNewestFirst() async {
        let older = PairedClient(
            fingerprint: fingerprintA,
            label: "Older",
            addedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = PairedClient(
            fingerprint: fingerprintB,
            label: "Newer",
            addedAt: Date(timeIntervalSince1970: 200)
        )

        await store.pair(older, route: .approval)
        await store.pair(newer, route: .approval)
        await store.settle()

        XCTAssertEqual(store.clients?.map(\.label), ["Newer", "Older"])
    }

    /// Must re-read the Keychain on each write; a cached snapshot would drop
    /// clients paired through a separate store on the same item.
    func testExternalPairingSurvivesSubsequentStoreWrite() async {
        let fingerprintC = "cc" + String(repeating: "0", count: 62)
        let firstClient = PairedClient(fingerprint: fingerprintA, label: "First", addedAt: Date())
        await store.pair(firstClient, route: .approval)
        await store.settle()

        let externalStorage = keychain.pairedClientStorage
        let externalClient = PairedClient(fingerprint: fingerprintB, label: "External", addedAt: Date())
        _ = await externalStorage.add(externalClient)

        let thirdClient = PairedClient(fingerprint: fingerprintC, label: "Third", addedAt: Date())
        await store.pair(thirdClient, route: .approval)
        await store.settle()

        let fingerprints = Set(store.clients?.map(\.fingerprint) ?? [])
        XCTAssertEqual(fingerprints, [fingerprintA, fingerprintB, fingerprintC])
    }

    func testContainsReflectsExternalWrite() async {
        let externalStorage = keychain.pairedClientStorage
        let externalClient = PairedClient(fingerprint: fingerprintB, label: "External", addedAt: Date())

        let before = await store.contains(fingerprint: fingerprintB)
        XCTAssertFalse(before)

        _ = await externalStorage.add(externalClient)

        let after = await store.contains(fingerprint: fingerprintB)
        XCTAssertTrue(after)
    }

    func testMigrateLeavesUserDefaultsWhenKeychainWriteFails() throws {
        let payload = try JSONEncoder().encode([
            PairedClient(fingerprint: fingerprintA, label: "Keep", addedAt: Date())
        ])
        userDefaults.set(payload, forKey: PairedClientStorage.storageKey)

        let keychain = InMemoryKeychainItem(failSave: true)
        let result = PairedClientStorage.migrateUserDefaultsIfNeeded(
            defaults: userDefaults,
            keychainLoad: keychain.load,
            keychainSave: keychain.save
        )

        XCTAssertEqual(result, .skippedKeychainWriteFailed)
        XCTAssertEqual(userDefaults.data(forKey: PairedClientStorage.storageKey), payload)
    }

    func testMigrateDeletesUserDefaultsOnlyAfterKeychainReadback() throws {
        let payload = try JSONEncoder().encode([
            PairedClient(fingerprint: fingerprintA, label: "Keep", addedAt: Date())
        ])
        userDefaults.set(payload, forKey: PairedClientStorage.storageKey)

        let keychain = InMemoryKeychainItem()
        let result = PairedClientStorage.migrateUserDefaultsIfNeeded(
            defaults: userDefaults,
            keychainLoad: keychain.load,
            keychainSave: keychain.save
        )

        XCTAssertEqual(result, .completed)
        XCTAssertNil(userDefaults.data(forKey: PairedClientStorage.storageKey))
        XCTAssertEqual(keychain.data, payload)
    }

    func testMigrateSkipsDeleteWhenReadbackDoesNotMatch() throws {
        let payload = try JSONEncoder().encode([
            PairedClient(fingerprint: fingerprintA, label: "Keep", addedAt: Date())
        ])
        userDefaults.set(payload, forKey: PairedClientStorage.storageKey)

        let result = PairedClientStorage.migrateUserDefaultsIfNeeded(
            defaults: userDefaults,
            keychainLoad: { .missing },
            keychainSave: { _ in true }
        )

        XCTAssertEqual(result, .skippedKeychainWriteFailed)
        XCTAssertEqual(userDefaults.data(forKey: PairedClientStorage.storageKey), payload)
    }

    func testMissingKeychainAndEmptyDefaultsWritesEmptySentinel() throws {
        let keychain = InMemoryKeychainItem()
        let result = PairedClientStorage.migrateUserDefaultsIfNeeded(
            defaults: userDefaults,
            keychainLoad: keychain.load,
            keychainSave: keychain.save
        )

        let emptySentinel = try JSONEncoder().encode([PairedClient]())
        XCTAssertEqual(result, .skippedEmpty)
        XCTAssertEqual(keychain.data, emptySentinel)
        XCTAssertNil(userDefaults.data(forKey: PairedClientStorage.storageKey))
    }

    func testExistingEmptySentinelDoesNotImportLaterUserDefaults() throws {
        let emptySentinel = try JSONEncoder().encode([PairedClient]())
        let keychain = InMemoryKeychainItem(emptySentinel)
        let payload = try JSONEncoder().encode([
            PairedClient(fingerprint: fingerprintA, label: "Injected", addedAt: Date())
        ])
        userDefaults.set(payload, forKey: PairedClientStorage.storageKey)

        let result = PairedClientStorage.migrateUserDefaultsIfNeeded(
            defaults: userDefaults,
            keychainLoad: keychain.load,
            keychainSave: keychain.save
        )

        XCTAssertEqual(result, .completed)
        XCTAssertEqual(keychain.saves, 0)
        XCTAssertEqual(keychain.data, emptySentinel)
        XCTAssertNotEqual(keychain.data, payload)
        XCTAssertNil(userDefaults.data(forKey: PairedClientStorage.storageKey))
    }

    func testFailedKeychainLoadDoesNotSaveOrDeleteOnMigrate() throws {
        let payload = try JSONEncoder().encode([
            PairedClient(fingerprint: fingerprintA, label: "Keep", addedAt: Date())
        ])
        userDefaults.set(payload, forKey: PairedClientStorage.storageKey)

        let keychain = InMemoryKeychainItem(loadFailure: errSecInteractionNotAllowed)
        let result = PairedClientStorage.migrateUserDefaultsIfNeeded(
            defaults: userDefaults,
            keychainLoad: keychain.load,
            keychainSave: keychain.save
        )

        XCTAssertEqual(keychain.saves, 0)
        XCTAssertEqual(result, .skippedKeychainWriteFailed)
        XCTAssertEqual(userDefaults.data(forKey: PairedClientStorage.storageKey), payload)
    }

    func testClientsIsNilWhenTheStoreCannotBeRead() async {
        let unreadable = PairedClientStore(
            storage: InMemoryKeychainItem(loadFailure: errSecInteractionNotAllowed).pairedClientStorage
        )
        await unreadable.reload()
        XCTAssertNil(unreadable.clients)
    }

    func testReloadPicksUpAnExternalWrite() async {
        let external = PairedClient(fingerprint: fingerprintB, label: "External", addedAt: Date())
        _ = await keychain.pairedClientStorage.add(external)

        await store.reload()

        XCTAssertEqual(store.clients, [external])
    }

    /// A Keychain prompt nobody answers holds a read for as long as it is up.
    /// The list is then unavailable after the deadline, not empty, and a
    /// client is not taken for paired.
    func testAReadThatDoesNotAnswerInTimeIsUnavailable() async throws {
        let gate = DispatchSemaphore(value: 0)
        let paired = try JSONEncoder().encode([PairedClient(fingerprint: fingerprintA, label: "A", addedAt: Date())])
        let keychain = InMemoryKeychainItem(paired)
        keychain.loadGate = gate
        let storage = keychain.pairedClientStorage

        let all = await storage.all(within: .milliseconds(50))
        let contains = await storage.contains(fingerprint: fingerprintA, within: .milliseconds(50))
        XCTAssertNil(all)
        XCTAssertFalse(contains)

        // The answered read can finish before the next call, which then
        // reads afresh; that read must not wait on the gate too.
        keychain.loadGate = nil
        gate.signal()
        let answered = await storage.all(within: .seconds(5))
        XCTAssertEqual(answered?.map(\.fingerprint), [fingerprintA])
    }

    /// A write behind a read held by a prompt fails at its deadline instead
    /// of waiting for the prompt, and does not land once it is answered.
    func testAWriteBehindAnUnansweredReadFailsAndNeverLands() async throws {
        let gate = DispatchSemaphore(value: 0)
        let existing = PairedClient(fingerprint: fingerprintA, label: "A", addedAt: Date())
        let keychain = InMemoryKeychainItem(try JSONEncoder().encode([existing]))
        keychain.loadGate = gate
        let storage = keychain.pairedClientStorage

        let all = await storage.all(within: .milliseconds(50))
        XCTAssertNil(all)
        let late = PairedClient(fingerprint: fingerprintB, label: "B", addedAt: Date())
        let added = await storage.add(late, within: .milliseconds(50))
        XCTAssertFalse(added)

        keychain.loadGate = nil
        gate.signal()
        let again = PairedClient(fingerprint: fingerprintA, label: "A again", addedAt: Date())
        let readded = await storage.add(again, within: .seconds(5))
        XCTAssertFalse(readded, "A was paired already")
        XCTAssertEqual(keychain.saves, 0, "the abandoned write did not land")
        let answered = await storage.all(within: .seconds(5))
        XCTAssertEqual(answered, [existing])
    }

    /// Every storage used to share one lock, so a read held by a prompt on
    /// one Keychain item stalled every other item's reads and writes.
    func testAnUnansweredReadDoesNotHoldUpAnotherItem() async {
        let gate = DispatchSemaphore(value: 0)
        let held = InMemoryKeychainItem()
        held.loadGate = gate
        defer { gate.signal() }
        let heldStorage = held.pairedClientStorage
        let otherStorage = InMemoryKeychainItem().pairedClientStorage

        let unavailable = await heldStorage.all(within: .milliseconds(50))
        XCTAssertNil(unavailable)
        let client = PairedClient(fingerprint: fingerprintA, label: "A", addedAt: Date())
        let added = await otherStorage.add(client, within: .seconds(5))
        XCTAssertTrue(added)
        let all = await otherStorage.all(within: .seconds(5))
        XCTAssertEqual(all, [client])
    }

    func testFailedKeychainLoadDoesNotSaveOnAddRemoveOrReset() async {
        let keychain = InMemoryKeychainItem(loadFailure: errSecInteractionNotAllowed)
        let storage = keychain.pairedClientStorage

        let all = await storage.all()
        XCTAssertNil(all)
        let added = await storage.add(PairedClient(fingerprint: fingerprintA, label: "A", addedAt: Date()))
        XCTAssertFalse(added)
        await storage.remove(fingerprint: fingerprintA)
        await storage.reset()

        XCTAssertEqual(keychain.saves, 0)
    }

    func testAddReturnsFalseWhenKeychainSaveFails() async {
        let payload = (try? JSONEncoder().encode([PairedClient]())) ?? Data()
        let keychain = InMemoryKeychainItem(payload, failSave: true)
        let storage = keychain.pairedClientStorage

        let added = await storage.add(PairedClient(fingerprint: fingerprintA, label: "A", addedAt: Date()))
        XCTAssertFalse(added)
        XCTAssertEqual(keychain.saves, 1)
        let all = await storage.all()
        XCTAssertEqual(all, [])
    }

    func testCorruptKeychainJSONIsUnavailableAndDoesNotSave() async {
        let keychain = InMemoryKeychainItem(Data("not-json".utf8))
        let storage = keychain.pairedClientStorage

        let all = await storage.all()
        XCTAssertNil(all)
        let added = await storage.add(PairedClient(fingerprint: fingerprintA, label: "A", addedAt: Date()))
        XCTAssertFalse(added)
        XCTAssertEqual(keychain.saves, 0)
    }

    #if DEBUG
        func testDebugFileIsAdoptedOnceAndDeletedAfterReadback() throws {
            let filePayload = try JSONEncoder().encode([
                PairedClient(fingerprint: fingerprintA, label: "Live", addedAt: Date())
            ])
            let olderPayload = try JSONEncoder().encode([
                PairedClient(fingerprint: fingerprintB, label: "Old", addedAt: Date())
            ])

            var stored: Data? = olderPayload
            var marked = false
            var deleteCount = 0
            let adopted = PairedClientStorage.adoptDebugFileOnce(
                markerLoad: { marked ? .data(Data([1])) : .missing },
                mark: {
                    marked = true
                    return true
                },
                fileRead: { .data(filePayload) },
                fileDelete: {
                    deleteCount += 1
                    return true
                },
                keychainSave: { data in
                    stored = data
                    return true
                },
                keychainLoad: { stored.map { .data($0) } ?? .missing }
            )

            XCTAssertTrue(adopted)
            XCTAssertEqual(stored, filePayload)
            XCTAssertTrue(marked)
            XCTAssertEqual(deleteCount, 1)
        }

        /// One machine across launches: the debug file, the marker and the
        /// Keychain list, each of which can be told to fail.
        private final class DebugAdoptionMachine {
            var file: Data?
            var marked = false
            var stored: Data?
            var saveSucceeds = true
            var readbackOverride: KeychainItem.LoadResult?
            var markSucceeds = true
            var deleteSucceeds = true

            init(file: Data) {
                self.file = file
            }

            func launch() -> Bool {
                PairedClientStorage.adoptDebugFileOnce(
                    markerLoad: { self.marked ? .data(Data([1])) : .missing },
                    mark: {
                        if self.markSucceeds { self.marked = true }
                        return self.markSucceeds
                    },
                    fileRead: { self.file.map { .data($0) } ?? .missing },
                    fileDelete: {
                        if self.deleteSucceeds { self.file = nil }
                        return self.deleteSucceeds
                    },
                    keychainSave: { data in
                        if self.saveSucceeds { self.stored = data }
                        return self.saveSucceeds
                    },
                    keychainLoad: {
                        self.readbackOverride ?? self.stored.map { .data($0) } ?? .missing
                    }
                )
            }
        }

        private func payload(_ fingerprint: String, _ label: String) throws -> Data {
            try JSONEncoder().encode([
                PairedClient(fingerprint: fingerprint, label: label, addedAt: Date())
            ])
        }

        func testDebugFileSurvivesAFailedKeychainSaveAndIsAdoptedNextLaunch() throws {
            let filePayload = try payload(fingerprintA, "Live")
            let machine = DebugAdoptionMachine(file: filePayload)
            machine.saveSucceeds = false

            XCTAssertFalse(machine.launch())
            XCTAssertEqual(machine.file, filePayload)
            XCTAssertFalse(machine.marked)

            machine.saveSucceeds = true
            XCTAssertTrue(machine.launch())
            XCTAssertEqual(machine.stored, filePayload)
            XCTAssertTrue(machine.marked)
            XCTAssertNil(machine.file)
        }

        func testDebugFileSurvivesAReadbackMismatchAndIsAdoptedNextLaunch() throws {
            let filePayload = try payload(fingerprintA, "Live")
            let machine = DebugAdoptionMachine(file: filePayload)
            machine.readbackOverride = .data(Data("[]".utf8))

            XCTAssertFalse(machine.launch())
            XCTAssertEqual(machine.file, filePayload)
            XCTAssertFalse(machine.marked)

            machine.readbackOverride = nil
            XCTAssertTrue(machine.launch())
            XCTAssertEqual(machine.stored, filePayload)
            XCTAssertTrue(machine.marked)
            XCTAssertNil(machine.file)
        }

        /// The marker write failed but the file is gone, so there is nothing
        /// left to adopt and the Keychain list that moved on stays.
        func testDebugFileIsNotAdoptedAgainWhenOnlyTheMarkerWriteFailed() throws {
            let filePayload = try payload(fingerprintA, "Live")
            let laterPayload = try payload(fingerprintB, "Paired later")
            let machine = DebugAdoptionMachine(file: filePayload)
            machine.markSucceeds = false

            XCTAssertTrue(machine.launch())
            XCTAssertEqual(machine.stored, filePayload)
            XCTAssertNil(machine.file)
            XCTAssertFalse(machine.marked)

            machine.stored = laterPayload
            machine.markSucceeds = true
            XCTAssertFalse(machine.launch())
            XCTAssertEqual(machine.stored, laterPayload)
            XCTAssertTrue(machine.marked)
        }

        /// The file outlives a failed delete, and the Keychain list moves on.
        /// The stale file must not come back over it.
        func testDebugFileThatCouldNotBeDeletedNeverOverwritesTheKeychainAgain() throws {
            let filePayload = try payload(fingerprintA, "Live")
            let laterPayload = try payload(fingerprintB, "Paired later")
            let machine = DebugAdoptionMachine(file: filePayload)
            machine.deleteSucceeds = false

            XCTAssertTrue(machine.launch())
            XCTAssertEqual(machine.stored, filePayload)
            XCTAssertEqual(machine.file, filePayload)
            XCTAssertTrue(machine.marked)

            machine.stored = laterPayload
            XCTAssertFalse(machine.launch())
            XCTAssertEqual(machine.stored, laterPayload)
        }

        /// Accepted: with neither the marker nor the delete, nothing records
        /// the adoption, so the next launch repeats it.
        func testDebugFileIsAdoptedAgainOnlyWhenBothMarkerAndDeleteFailed() throws {
            let filePayload = try payload(fingerprintA, "Live")
            let laterPayload = try payload(fingerprintB, "Paired later")
            let machine = DebugAdoptionMachine(file: filePayload)
            machine.markSucceeds = false
            machine.deleteSucceeds = false

            XCTAssertTrue(machine.launch())
            machine.stored = laterPayload
            XCTAssertTrue(machine.launch())
            XCTAssertEqual(machine.stored, filePayload)
        }

        func testDebugFileIsIgnoredOnceMarked() throws {
            let filePayload = try JSONEncoder().encode([
                PairedClient(fingerprint: fingerprintA, label: "Late", addedAt: Date())
            ])

            var saveCount = 0
            var deleteCount = 0
            let adopted = PairedClientStorage.adoptDebugFileOnce(
                markerLoad: { .data(Data([1])) },
                mark: { true },
                fileRead: { .data(filePayload) },
                fileDelete: {
                    deleteCount += 1
                    return true
                },
                keychainSave: { _ in
                    saveCount += 1
                    return true
                },
                keychainLoad: { .missing }
            )

            XCTAssertFalse(adopted)
            XCTAssertEqual(saveCount, 0)
            XCTAssertEqual(deleteCount, 0)
        }

        func testMissingDebugFileSetsMarker() {
            var marked = false
            var saveCount = 0
            let adopted = PairedClientStorage.adoptDebugFileOnce(
                markerLoad: { .missing },
                mark: {
                    marked = true
                    return true
                },
                fileRead: { .missing },
                fileDelete: { true },
                keychainSave: { _ in
                    saveCount += 1
                    return true
                },
                keychainLoad: { .missing }
            )

            XCTAssertFalse(adopted)
            XCTAssertTrue(marked)
            XCTAssertEqual(saveCount, 0)
        }

        func testUnreadableOrUndecodableDebugFileIsLeftAlone() {
            let reads: [SecretFileStore.Read] = [.failed, .data(Data("not-json".utf8))]
            for read in reads {
                var marked = false
                var saveCount = 0
                var deleteCount = 0
                let adopted = PairedClientStorage.adoptDebugFileOnce(
                    markerLoad: { .missing },
                    mark: {
                        marked = true
                        return true
                    },
                    fileRead: { read },
                    fileDelete: {
                        deleteCount += 1
                        return true
                    },
                    keychainSave: { _ in
                        saveCount += 1
                        return true
                    },
                    keychainLoad: { .missing }
                )

                XCTAssertFalse(adopted)
                XCTAssertFalse(marked)
                XCTAssertEqual(saveCount, 0)
                XCTAssertEqual(deleteCount, 0)
            }
        }
    #endif
}
