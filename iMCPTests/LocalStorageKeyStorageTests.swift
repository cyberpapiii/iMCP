import Foundation
import XCTest

@testable import iMCP

final class LocalStorageKeyStorageTests: XCTestCase {
    private func storage(
        database: InMemoryKeychainItem,
        identity: InMemoryKeychainItem,
        randomSecret: @escaping @Sendable () -> Data? = { Data(repeating: 9, count: 32) }
    ) -> LocalStorageKeyStorage {
        peopleKeyStorage(database: database, identity: identity, randomSecret: randomSecret)
    }

    func testSeparateStoresDistinguishMissingDataAndUnavailable() async {
        let database = InMemoryKeychainItem()
        let identity = InMemoryKeychainItem()
        let empty = storage(database: database, identity: identity)
        let missingKey = await empty.databaseKey()
        let missingIdentity = await empty.identitySecret()
        XCTAssertEqual(missingKey, .missing)
        XCTAssertEqual(missingIdentity, .missing)

        database.data = Data(repeating: 1, count: 32)
        let key = await empty.databaseKey()
        let stillMissingIdentity = await empty.identitySecret()
        XCTAssertEqual(key, .found(Data(repeating: 1, count: 32)))
        XCTAssertEqual(stillMissingIdentity, .missing)

        let unavailable = storage(
            database: InMemoryKeychainItem(loadFailure: errSecAuthFailed),
            identity: InMemoryKeychainItem(loadFailure: errSecInteractionNotAllowed)
        )
        let unavailableKey = await unavailable.databaseKey()
        let unavailableIdentity = await unavailable.identitySecret()
        XCTAssertEqual(unavailableKey, .unavailable)
        XCTAssertEqual(unavailableIdentity, .unavailable)
    }

    func testValidationFailurePreservesThePriorDatabaseKey() async {
        let database = InMemoryKeychainItem()
        let identity = InMemoryKeychainItem()
        let oldKey = Data(repeating: 1, count: 32)
        database.data = oldKey
        let store = storage(database: database, identity: identity)

        do {
            try await store.replaceDatabaseKey(Data(repeating: 2, count: 32)) { _ in
                throw LocalStoragePeopleError.incorrectKey
            }
            XCTFail("Expected validation to fail")
        } catch {
            XCTAssertEqual(error as? LocalStoragePeopleError, .incorrectKey)
        }
        XCTAssertEqual(database.data, oldKey)
    }

    func testFailedAtomicReplacementPreservesThePriorDatabaseKey() async {
        let oldKey = Data(repeating: 1, count: 32)
        let database = InMemoryKeychainItem(oldKey, failSave: true)
        let store = storage(database: database, identity: InMemoryKeychainItem())

        do {
            try await store.replaceDatabaseKey(Data(repeating: 2, count: 32)) { _ in }
            XCTFail("Expected persistence to fail")
        } catch {
            XCTAssertEqual(
                error as? LocalStorageKeyStorageError,
                .couldNotPersistDatabaseKey
            )
        }
        XCTAssertEqual(database.data, oldKey)
    }

    func testUnavailableDatabaseKeyIsNeverOverwritten() async {
        let database = InMemoryKeychainItem(loadFailure: errSecInteractionNotAllowed)
        let store = storage(database: database, identity: InMemoryKeychainItem())

        do {
            try await store.replaceDatabaseKey(Data(repeating: 2, count: 32)) { _ in }
            XCTFail("Expected the unavailable Keychain to block replacement")
        } catch {
            XCTAssertEqual(error as? LocalStorageKeyStorageError, .databaseKeyUnavailable)
        }
        XCTAssertEqual(database.saves, 0)
    }

    func testIdentitySecretIsGeneratedOnceAndNeverStoredWithTheDatabaseKey() async throws {
        let database = InMemoryKeychainItem()
        let identity = InMemoryKeychainItem()
        let generated = Data(repeating: 7, count: 32)
        let store = storage(
            database: database,
            identity: identity,
            randomSecret: { generated }
        )

        let first = try await store.loadOrCreateIdentitySecret()
        let second = try await store.loadOrCreateIdentitySecret()
        XCTAssertEqual([first, second], [generated, generated])
        XCTAssertEqual(identity.data, generated)
        XCTAssertNil(database.data)
    }

    func testDeadlineReadsCoalesceAndSuccessfulMutationInvalidatesTheResult() async throws {
        let gate = DispatchSemaphore(value: 0)
        let firstKey = Data(repeating: 1, count: 32)
        let replacementKey = Data(repeating: 2, count: 32)
        let database = InMemoryKeychainItem(firstKey)
        database.loadGate = gate
        let store = storage(database: database, identity: InMemoryKeychainItem())

        async let first = store.databaseKey(within: .milliseconds(50))
        async let second = store.databaseKey(within: .milliseconds(50))
        let timedOut = await [first, second]
        XCTAssertEqual(timedOut, [.unavailable, .unavailable])
        XCTAssertEqual(database.loads, 1)

        gate.signal()
        let arrived = await store.databaseKey(within: .seconds(2))
        XCTAssertEqual(arrived, .found(firstKey))
        gate.signal()
        try await store.replaceDatabaseKey(replacementKey) { _ in }
        gate.signal()
        let refreshed = await store.databaseKey(within: .seconds(2))
        XCTAssertEqual(refreshed, .found(replacementKey))
    }

    func testTransientUnavailableDeadlineReadIsNotCached() async {
        let key = Data(repeating: 4, count: 32)
        let database = InMemoryKeychainItem(key)
        database.failLoad(onAttempt: 1, with: errSecInteractionNotAllowed)
        let store = storage(database: database, identity: InMemoryKeychainItem())

        let locked = await store.databaseKey(within: .seconds(2))
        XCTAssertEqual(locked, .unavailable)
        let unlocked = await store.databaseKey(within: .seconds(2))
        XCTAssertEqual(unlocked, .found(key))
        let cached = await store.databaseKey(within: .seconds(2))
        XCTAssertEqual(cached, .found(key))
        // The failed read is forgotten; the successful one is kept.
        XCTAssertEqual(database.loads, 2)
    }

    func testMissingDeadlineReadIsNotCached() async {
        let database = InMemoryKeychainItem()
        let key = Data(repeating: 5, count: 32)
        let store = storage(database: database, identity: InMemoryKeychainItem())

        let before = await store.databaseKey(within: .seconds(2))
        XCTAssertEqual(before, .missing)
        // Set behind the store's back, so no save invalidates the reader.
        database.data = key
        let after = await store.databaseKey(within: .seconds(2))
        XCTAssertEqual(after, .found(key))
    }
}
