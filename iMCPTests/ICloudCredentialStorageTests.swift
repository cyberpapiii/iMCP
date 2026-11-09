import Foundation
import Security
import XCTest
import os

@testable import iMCP

final class ICloudCredentialStorageTests: XCTestCase {
    private func credentials(trustedAt: Date = Date()) -> ICloudCredentials {
        ICloudCredentials(
            accountName: "someone@example.com",
            accountCountry: "USA",
            sessionToken: "session",
            trustToken: "trust",
            webAuthToken: "webauth",
            webAuthUser: "webuser",
            trustedAt: trustedAt
        )
    }

    func testSaveThenLoadRoundTrips() async {
        let storage = InMemoryKeychainItem().iCloudCredentialStorage

        let saved = credentials()
        let didSave = await storage.save(saved)
        XCTAssertTrue(didSave)
        XCTAssertEqual(storage.loadBlocking(), .found(saved))
        let didClear = await storage.clear()
        XCTAssertTrue(didClear)
        XCTAssertEqual(storage.loadBlocking(), .missing)
    }

    /// The rule this type exists to enforce. A Keychain that is momentarily
    /// unreadable is not a signed-out user, and treating it as one presents a
    /// sign-in sheet that then overwrites live tokens.
    func testKeychainFailureIsNotReadAsSignedOut() {
        let storage = InMemoryKeychainItem(loadFailure: errSecAuthFailed).iCloudCredentialStorage
        XCTAssertEqual(storage.loadBlocking(), .unavailable)
        XCTAssertNotEqual(storage.loadBlocking(), .missing)
    }

    /// A record an older build wrote has no `lastUnattendedPasswordAt`. It
    /// still decodes, with every key it does have meaning what it meant.
    func testARecordWithoutThePasswordMomentStillDecodes() throws {
        let old = Data(
            """
            {"accountName":"someone@example.com","accountCountry":"USA","sessionToken":"session",
            "trustToken":"trust","trustedAt":700000000,"password":"pw",
            "lastAutomaticReauthenticationAt":700000100,"accountRepairPending":false}
            """.utf8
        )
        let storage = InMemoryKeychainItem(old).iCloudCredentialStorage

        guard case .found(let record) = storage.loadBlocking() else { return XCTFail("expected the record") }
        XCTAssertNil(record.lastUnattendedPasswordAt)
        XCTAssertEqual(record.accountName, "someone@example.com")
        XCTAssertEqual(record.password, "pw")
        XCTAssertEqual(record.trustedAt, Date(timeIntervalSinceReferenceDate: 700_000_000))
        XCTAssertEqual(record.lastAutomaticReauthenticationAt, Date(timeIntervalSinceReferenceDate: 700_000_100))
        XCTAssertEqual(record.accountRepairPending, false)
    }

    /// The one key added to the stored JSON, under its own name, so an older
    /// build reading the record skips it.
    func testThePasswordMomentRoundTripsUnderItsOwnKey() async throws {
        let keychain = InMemoryKeychainItem()
        let storage = keychain.iCloudCredentialStorage
        var record = credentials()
        record.lastUnattendedPasswordAt = Date(timeIntervalSinceReferenceDate: 700_000_200)

        await storage.save(record)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(keychain.data)) as? [String: Any]
        )
        XCTAssertEqual(json["lastUnattendedPasswordAt"] as? Double, 700_000_200)
        XCTAssertEqual(storage.loadBlocking(), .found(record))
    }

    func testUndecodableDataIsUnavailableRatherThanMissing() {
        let storage = InMemoryKeychainItem(Data("not json".utf8)).iCloudCredentialStorage
        XCTAssertEqual(storage.loadBlocking(), .unavailable)
    }

    /// The store used to start a new detached read on every call, so an
    /// unanswered prompt piled up one blocked read per Find My call.
    func testCallersShareABlockedRead() async {
        let gate = DispatchSemaphore(value: 0)
        let keychain = InMemoryKeychainItem()
        keychain.loadGate = gate
        let storage = keychain.iCloudCredentialStorage

        let first = await storage.load(within: .milliseconds(50))
        let second = await storage.load(within: .milliseconds(50))
        XCTAssertEqual([first, second], [.unavailable, .unavailable])
        XCTAssertEqual(keychain.loads, 1)
        keychain.loadGate = nil
        gate.signal()
    }

    /// The record a write replaces is read and the new one saved in one call
    /// on the item's queue: a save queued meanwhile lands after it, not in
    /// between.
    func testAnUpdateReadsAndWritesInOneCall() async throws {
        let keychain = InMemoryKeychainItem()
        let storage = keychain.iCloudCredentialStorage
        let first = credentials()
        await storage.save(first)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let seen = OSAllocatedUnfairLock<ICloudCredentialStorage.LoadResult?>(initialState: nil)

        let update = Task {
            try await storage.update { stored in
                seen.withLock { $0 = stored }
                entered.signal()
                release.wait()
                var next = first
                next.sessionToken = "from-update"
                return next
            }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                entered.wait()
                continuation.resume()
            }
        }
        var other = first
        other.sessionToken = "queued-meanwhile"
        let queuedSave = Task { await storage.save(other) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(keychain.saves, 1, "the save waits for the update")
        release.signal()
        let updated = try await update.value
        _ = await queuedSave.value

        XCTAssertEqual(seen.withLock { $0 }, .found(first))
        XCTAssertEqual(updated?.sessionToken, "from-update")
        XCTAssertEqual(storage.loadBlocking(), .found(other), "the save queued meanwhile landed last")
    }

    func testAnUpdateThatThrowsSavesNothing() async {
        let keychain = InMemoryKeychainItem(loadFailure: errSecInteractionNotAllowed)
        let storage = keychain.iCloudCredentialStorage
        do {
            _ = try await storage.update { stored throws(ICloudAuthError) in
                guard case .found = stored else { throw .credentialsUnreadable }
                return nil
            }
            XCTFail("expected the update to stop")
        } catch {
            XCTAssertEqual(error, .credentialsUnreadable)
        }
        XCTAssertEqual(keychain.saves, 0)
    }
}
