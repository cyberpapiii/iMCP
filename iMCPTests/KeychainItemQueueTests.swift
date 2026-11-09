import Foundation
import Security
import XCTest

@testable import iMCP

/// A Keychain read can block on a prompt nobody answers. Callers give up at
/// their deadline, and none of them may start another read behind the
/// blocked one.
final class KeychainItemQueueTests: XCTestCase {
    /// An item that holds one byte, so a test can count in it.
    private func queue(
        over keychain: InMemoryKeychainItem,
        keepsFound: Bool = false,
        label: String = "test"
    ) -> KeychainItemQueue<Int> {
        KeychainItemQueue(
            label: label,
            keepsFound: keepsFound,
            calls: keychain.calls,
            decode: { $0.first.map(Int.init) },
            encode: { Data([UInt8($0)]) }
        )
    }

    func testCallersShareABlockedReadAndTheNextCallReadsAfresh() async {
        let gate = DispatchSemaphore(value: 0)
        let keychain = InMemoryKeychainItem(Data([1]))
        keychain.loadGate = gate
        let read = queue(over: keychain)

        let patient = Task { await read.load(within: .seconds(5)) }
        async let first = read.load(within: .milliseconds(50))
        async let second = read.load(within: .milliseconds(50))
        let timedOut = await [first, second]
        XCTAssertEqual(timedOut, [.unavailable, .unavailable])
        XCTAssertEqual(keychain.loads, 1, "no second read behind the blocked one")

        keychain.data = Data([2])
        keychain.loadGate = nil
        gate.signal()
        let arrived = await patient.value
        XCTAssertEqual(arrived, .found(2))

        keychain.data = Data([3])
        let fresh = await read.load(within: .seconds(2))
        XCTAssertEqual(fresh, .found(3), "a finished read is not kept")
        XCTAssertEqual(keychain.loads, 2)
    }

    /// Only `missing` is absence: a failed read and data that does not
    /// decode are both `unavailable`, on every way in.
    func testOnlyAMissingItemIsAbsence() async {
        let missing = queue(over: InMemoryKeychainItem())
        let failed = queue(over: InMemoryKeychainItem(loadFailure: errSecInteractionNotAllowed))
        let undecodable = queue(over: InMemoryKeychainItem(Data()))

        let loaded = [
            await missing.load(within: .seconds(2)),
            await failed.load(within: .seconds(2)),
            await undecodable.load(within: .seconds(2)),
        ]
        XCTAssertEqual(loaded, [.missing, .unavailable, .unavailable])
        let performed = [
            await missing.perform { $0.read() },
            await failed.perform { $0.read() },
            await undecodable.perform { $0.read() },
        ]
        XCTAssertEqual(performed, loaded)
        XCTAssertEqual(
            [missing.loadBlocking(), failed.loadBlocking(), undecodable.loadBlocking()],
            loaded
        )
    }

    func testAKeptValueLastsUntilAWrite() async {
        let keychain = InMemoryKeychainItem(Data([1]))
        let read = queue(over: keychain, keepsFound: true)

        let first = await read.load(within: .seconds(2))
        keychain.data = Data([5])
        let second = await read.load(within: .seconds(2))
        XCTAssertEqual([first, second], [.found(1), .found(1)])
        XCTAssertEqual(keychain.loads, 1)

        let saved = await read.perform { $0.save(2) }
        XCTAssertTrue(saved)
        let third = await read.load(within: .seconds(2))
        XCTAssertEqual(third, .found(2))
    }

    /// A write that fails may still have changed the item, so it drops the
    /// kept value too.
    func testAFailedWriteAlsoDropsTheKeptValue() async {
        let keychain = InMemoryKeychainItem(Data([1]), failSave: true, failDelete: true)
        let read = queue(over: keychain, keepsFound: true)

        _ = await read.load(within: .seconds(2))
        let saved = await read.perform { $0.save(2) }
        XCTAssertFalse(saved)
        _ = await read.load(within: .seconds(2))
        let deleted = await read.perform { $0.delete() }
        XCTAssertFalse(deleted)
        _ = await read.load(within: .seconds(2))
        XCTAssertEqual(keychain.loads, 3)
    }

    func testAKeptReadStillForgetsAMissingItem() async {
        let keychain = InMemoryKeychainItem()
        let read = queue(over: keychain, keepsFound: true)

        let missing = await read.load(within: .seconds(2))
        XCTAssertEqual(missing, .missing)
        keychain.data = Data([7])
        let found = await read.load(within: .seconds(2))
        XCTAssertEqual(found, .found(7))
    }

    /// A write queued behind a read held by a prompt fails at its deadline,
    /// and it does not land once the prompt is answered: the caller was told
    /// it failed.
    func testWorkThatHasNotStartedByItsDeadlineNeverRuns() async {
        let gate = DispatchSemaphore(value: 0)
        let keychain = InMemoryKeychainItem(Data([1]))
        keychain.loadGate = gate
        let item = queue(over: keychain)
        let ran = Counter()

        let read = await item.load(within: .milliseconds(50))
        XCTAssertEqual(read, .unavailable)
        let abandoned = await item.run(within: .milliseconds(50)) { _ in ran.increment() }
        XCTAssertNil(abandoned)

        keychain.loadGate = nil
        gate.signal()
        let later = await item.run(within: .seconds(5)) { _ in 7 }
        XCTAssertEqual(later, 7)
        XCTAssertEqual(ran.value, 0, "the abandoned work was skipped")
    }

    /// `perform` has no deadline: it waits out a blocked call ahead of it
    /// without holding a thread, then runs, in order.
    func testPerformWaitsBehindABlockedCallAndThenRuns() async {
        let gate = DispatchSemaphore(value: 0)
        let keychain = InMemoryKeychainItem(Data([1]))
        keychain.loadGate = gate
        let item = queue(over: keychain)

        let held = await item.load(within: .milliseconds(50))
        XCTAssertEqual(held, .unavailable)
        let writeThenRead = Task { (await item.perform { $0.save(4) }, await item.perform { $0.read() }) }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(keychain.saves, 0, "the write waits behind the held read")

        keychain.loadGate = nil
        gate.signal()
        let (wrote, readBack) = await writeThenRead.value
        XCTAssertTrue(wrote)
        XCTAssertEqual(readBack, .found(4))
    }

    /// Each item has its own queue. A prompt held over one item used to hold
    /// every other storage's reads and writes too, behind one shared lock.
    func testABlockedCallHoldsUpOnlyItsOwnItem() async {
        let gate = DispatchSemaphore(value: 0)
        let blockedItem = InMemoryKeychainItem(Data([1]))
        blockedItem.loadGate = gate
        let blocked = queue(over: blockedItem, label: "blocked")
        let free = queue(over: InMemoryKeychainItem(Data([2])), label: "free")
        defer {
            blockedItem.loadGate = nil
            gate.signal()
        }

        let held = await blocked.load(within: .milliseconds(50))
        XCTAssertEqual(held, .unavailable)
        let read = await free.load(within: .seconds(5))
        XCTAssertEqual(read, .found(2))
        let wrote = await free.run(within: .seconds(5)) { $0.save(3) }
        XCTAssertEqual(wrote, true)
        let performed = await free.perform { $0.read() }
        XCTAssertEqual(performed, .found(3))
    }
}
