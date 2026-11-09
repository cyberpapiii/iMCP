import Foundation
import XCTest

@testable import iMCP

final class FindMyPeopleReadinessTests: XCTestCase {
    func testDefaultOffGateBecomesReadyOnlyAfterValidatedImport() async throws {
        let database = InMemoryKeychainItem()
        let identity = InMemoryKeychainItem()
        let key = Data(repeating: 3, count: 32)
        let readiness = FindMyPeopleReadiness(
            storage: peopleKeyStorage(database: database, identity: identity),
            peopleEnabled: false,
            loadPeople: { candidate in
                XCTAssertEqual(candidate, key)
                return []
            }
        )

        let initialState = await readiness.state()
        let initialSecrets = await readiness.secretsState()
        XCTAssertEqual(initialState, .disabled)
        XCTAssertEqual(initialSecrets, .missingKey)
        try await readiness.importDatabaseKey(key)
        XCTAssertEqual(database.data, key)
        XCTAssertEqual(identity.data, Data(repeating: 8, count: 32))
        let importedState = await readiness.state()
        let importedSecrets = await readiness.secretsState()
        let health = await readiness.health()
        XCTAssertEqual(importedState, .disabled)
        XCTAssertEqual(importedSecrets, .ready)
        XCTAssertEqual(health.rowCount, 0)
        XCTAssertNotNil(health.lastSuccess)
        XCTAssertNil(health.lastErrorCategory)

        await readiness.setPeopleEnabled(true)
        let readyState = await readiness.state()
        let locationIsActivated = await LocationService.testing(
            peopleReadiness: readiness,
            historyStore: LocationHistoryStore(url: temporaryDirectoryURL().appendingPathComponent("history.sqlite"))
        ).isActivated
        XCTAssertEqual(readyState, .ready)
        XCTAssertTrue(locationIsActivated)
    }

    func testOpaqueIdentifiersAreStableAndDoNotExposeServerIdentifiers() {
        let secret = Data(repeating: 5, count: 32)
        let first = FindMyPeopleReadiness.opaqueIdentifier(
            serverIdentifier: "apple-server-id",
            identitySecret: secret
        )
        let repeated = FindMyPeopleReadiness.opaqueIdentifier(
            serverIdentifier: "apple-server-id",
            identitySecret: secret
        )
        let other = FindMyPeopleReadiness.opaqueIdentifier(
            serverIdentifier: "other-server-id",
            identitySecret: secret
        )

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, other)
        XCTAssertTrue(first.hasPrefix("friend_"))
        XCTAssertFalse(first.contains("apple-server-id"))
    }

    func testRevocationDuringProviderReadPreventsDisclosure() async throws {
        let database = InMemoryKeychainItem()
        let identity = InMemoryKeychainItem()
        database.data = Data(repeating: 3, count: 32)
        identity.data = Data(repeating: 4, count: 32)
        let gate = AsyncGate()
        let readiness = FindMyPeopleReadiness(
            storage: peopleKeyStorage(database: database, identity: identity),
            peopleEnabled: true,
            loadPeople: { _ in
                await gate.wait()
                return [localStoragePerson(id: "robin", name: "Robin")]
            }
        )

        let read = Task { try await readiness.friends() }
        await gate.waitUntilWaiting()
        await readiness.setPeopleEnabled(false)
        await gate.open()

        do {
            _ = try await read.value
            XCTFail("Expected the revoked read to be discarded")
        } catch {
            XCTAssertEqual(error as? FindMyPeopleToolError, .disabled)
        }
    }

    func testPurgeRevokesAndQuiescesBeforeDeletionAndStaysOffOnPartialFailure() async {
        let events = EventRecorder()
        let database = InMemoryKeychainItem(Data(repeating: 3, count: 32))
        let identity = InMemoryKeychainItem(Data(repeating: 4, count: 32), failDelete: true)
        let readiness = FindMyPeopleReadiness(
            storage: peopleKeyStorage(database: database, identity: identity),
            peopleEnabled: true,
            quiescePeopleSampling: { await events.append("quiesce") },
            loadPeople: { _ in [] }
        )

        do {
            try await LocationDataLifecycle.purge(
                readiness: readiness,
                deletePeopleHistory: { await events.append("history") },
                clearPreparedHandoff: { await events.append("handoff") }
            )
            XCTFail("Expected a typed partial purge failure")
        } catch {
            XCTAssertEqual(
                error as? FindMyPeopleLifecycleError,
                .secretPurgeFailed(databaseKeyCleared: true, identitySecretCleared: false)
            )
        }
        let recordedEvents = await events.values
        let isEnabled = await readiness.isPeopleEnabled()
        XCTAssertEqual(recordedEvents, ["quiesce", "history", "handoff"])
        XCTAssertFalse(isEnabled)
    }

    /// The pending setup is part of "Purge Everything": a failure to delete
    /// it is reported, not swallowed, and the secrets still go first.
    func testPurgeReportsAPendingSetupItCouldNotDelete() async throws {
        let database = InMemoryKeychainItem()
        let identity = InMemoryKeychainItem()
        database.data = Data(repeating: 3, count: 32)
        identity.data = Data(repeating: 4, count: 32)
        let readiness = FindMyPeopleReadiness(
            storage: peopleKeyStorage(database: database, identity: identity),
            peopleEnabled: true,
            loadPeople: { _ in [] }
        )

        do {
            try await LocationDataLifecycle.purge(
                readiness: readiness,
                deletePeopleHistory: {},
                clearPreparedHandoff: { throw FindMyPeopleBootstrapError.keychainUnavailable }
            )
            XCTFail("Expected the pending setup failure")
        } catch {
            XCTAssertEqual(error as? FindMyPeopleLifecycleError, .setupPurgeFailed)
        }
        XCTAssertNil(database.data)
        XCTAssertNil(identity.data)
        let isEnabled = await readiness.isPeopleEnabled()
        XCTAssertFalse(isEnabled)
    }

    /// "Clear Key Only" leaves the identity secret on purpose, so a failure
    /// reports both secrets as still there.
    func testClearingTheKeyAloneReportsWhatIsStillStored() async throws {
        let identity = InMemoryKeychainItem(Data(repeating: 4, count: 32))
        let readiness = FindMyPeopleReadiness(
            storage: peopleKeyStorage(
                database: InMemoryKeychainItem(Data(repeating: 3, count: 32), failDelete: true),
                identity: identity
            ),
            peopleEnabled: true,
            loadPeople: { _ in [] }
        )

        do {
            try await readiness.clearDatabaseKey()
            XCTFail("Expected the key deletion failure")
        } catch {
            XCTAssertEqual(
                error as? FindMyPeopleLifecycleError,
                .secretPurgeFailed(databaseKeyCleared: false, identitySecretCleared: false)
            )
        }
        XCTAssertNotNil(identity.data)
        let isEnabled = await readiness.isPeopleEnabled()
        XCTAssertFalse(isEnabled)
    }
}

private actor EventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
