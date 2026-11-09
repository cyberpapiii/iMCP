import Foundation
import Security

@testable import iMCP

/// One Keychain item held in memory: what a storage loads, saves, and
/// deletes, and what a test reads back, plants, or makes fail. Every app
/// storage over a Keychain item is built from one of these.
final class InMemoryKeychainItem: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    private var loadStatus: OSStatus?
    private var saveFails: Bool
    private var deleteFails: Bool
    private var gate: DispatchSemaphore?
    private var heldSave: DispatchSemaphore?
    private var loadCount = 0
    private var failedLoadCount = 0
    private var saveCount = 0
    private var failingAttempts: [Int: OSStatus] = [:]
    private var failureAfterSaves: (saves: Int, status: OSStatus)?
    private let savesStarted = CountLatch()

    init(_ data: Data? = nil, loadFailure: OSStatus? = nil, failSave: Bool = false, failDelete: Bool = false) {
        stored = data
        loadStatus = loadFailure
        saveFails = failSave
        deleteFails = failDelete
    }

    var data: Data? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// While set, every read fails with this status, as a locked
    /// (`errSecInteractionNotAllowed`) or refused (`errSecAuthFailed`)
    /// Keychain answers. Set it part-way through to lock the Keychain then.
    var loadFailure: OSStatus? {
        get { lock.withLock { loadStatus } }
        set { lock.withLock { loadStatus = newValue } }
    }

    /// A save that fails stores nothing.
    var failSave: Bool {
        get { lock.withLock { saveFails } }
        set { lock.withLock { saveFails = newValue } }
    }

    /// A delete that fails keeps the data.
    var failDelete: Bool {
        get { lock.withLock { deleteFails } }
        set { lock.withLock { deleteFails = newValue } }
    }

    /// Every read waits for one `signal()` before it answers, as a read
    /// behind a Keychain prompt nobody has answered yet does.
    var loadGate: DispatchSemaphore? {
        get { lock.withLock { gate } }
        set { lock.withLock { gate = newValue } }
    }

    /// Every save waits for one `signal()` before it lands, as a write behind
    /// an unanswered prompt does. `saves` counts it once it is waiting.
    var saveGate: DispatchSemaphore? {
        get { lock.withLock { heldSave } }
        set { lock.withLock { heldSave = newValue } }
    }

    /// Reads started so far, blocked and failed ones included.
    var loads: Int { lock.withLock { loadCount } }

    /// Reads that were made to fail so far.
    var failedLoads: Int { lock.withLock { failedLoadCount } }

    /// Saves attempted so far, failed ones included.
    var saves: Int { lock.withLock { saveCount } }

    /// Returns once `count` saves have started, held ones included, or fails
    /// the test after `CountLatch.deadline`.
    func waitForSaves(_ count: Int = 1, file: StaticString = #filePath, line: UInt = #line) async {
        await savesStarted.wait(count: count, what: "Keychain saves started", file: file, line: line)
    }

    /// Read number `attempt` (counting from 1) fails with `status`, once.
    func failLoad(onAttempt attempt: Int, with status: OSStatus = errSecAuthFailed) {
        lock.withLock { failingAttempts[attempt] = status }
    }

    /// The first read made once `count` saves have been attempted fails with
    /// `status`, once. With no count, that is the next read.
    func failNextLoad(afterSaves count: Int = 0, with status: OSStatus = errSecAuthFailed) {
        lock.withLock { failureAfterSaves = (count, status) }
    }

    func load() -> KeychainItem.LoadResult {
        let (attempt, gate) = lock.withLock {
            loadCount += 1
            return (loadCount, self.gate)
        }
        gate?.wait()
        return lock.withLock {
            guard let status = failure(onAttempt: attempt) else { return stored.map { .data($0) } ?? .missing }
            failedLoadCount += 1
            return .failed(status)
        }
    }

    /// Called under the lock.
    private func failure(onAttempt attempt: Int) -> OSStatus? {
        if let status = failingAttempts.removeValue(forKey: attempt) { return status }
        if let scheduled = failureAfterSaves, saveCount >= scheduled.saves {
            failureAfterSaves = nil
            return scheduled.status
        }
        return loadStatus
    }

    func save(_ data: Data) -> Bool {
        let (count, gate) = lock.withLock {
            saveCount += 1
            return (saveCount, heldSave)
        }
        let savesStarted = savesStarted
        Task { await savesStarted.reach(count) }
        gate?.wait()
        return lock.withLock {
            guard !saveFails else { return false }
            stored = data
            return true
        }
    }

    func delete() -> Bool {
        lock.withLock {
            guard !deleteFails else { return false }
            stored = nil
            return true
        }
    }

    var calls: KeychainItemCalls {
        KeychainItemCalls(load: { self.load() }, save: { self.save($0) }, delete: { self.delete() })
    }

    var pairedClientStorage: PairedClientStorage {
        PairedClientStorage(calls: calls)
    }

    var iCloudCredentialStorage: ICloudCredentialStorage {
        ICloudCredentialStorage(calls: calls)
    }
}
