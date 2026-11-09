import CommonCrypto
import CryptoKit
import Foundation
import SQLite3
import XCTest

@testable import iMCP

final class LocalStoragePeopleProviderTests: XCTestCase {
    private let pageSize = 4096
    private let contentSize = 4084
    private let key = Data(0 ..< 32)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try makeTemporaryDirectory()
    }

    func testIndependentKnownAnswerPageAndWALVectors() throws {
        let plaintext = Data((0 ..< contentSize).map { UInt8($0 % 251) })
        let reserved = Data(0xA0 ..< 0xAC)
        let encrypted = try encryptedPage(
            plaintext: plaintext,
            pageIndex: 1,
            key: key,
            reserved: reserved
        )

        // Frozen with OpenSSL 3, independently of this Swift implementation.
        XCTAssertEqual(
            encrypted.prefix(64).hex,
            "066718b989a705100e205890554591dc83e0a20b34b04dfb76d21406bc8bbc42fd302579f8795b9bc801abbfd1f8490e7752d263edf2cc7b6161c5191036d225"
        )
        XCTAssertEqual(
            Data(SHA256.hash(data: encrypted)).hex,
            "8e5765e1178b9afa2aabd056a46eab2b95f2d7dbc12c66a634781a751f3ddd4b"
        )
        XCTAssertEqual(
            try LocalStoragePeopleProvider.decryptPage(encrypted, pageIndex: 1, key: key),
            plaintext
        )

        let wal = makeWAL(pages: [(index: 1, body: encrypted)], committedPageCount: 2)
        XCTAssertEqual(
            wal.prefix(32).hex,
            "377f0683002de2180000100000000001aaaa1111bbbb2222c0aef7e9234301c5"
        )
        XCTAssertEqual(
            wal[32 ..< 56].hex,
            "0000000200000002aaaa1111bbbb222265c27e5562298663"
        )
        XCTAssertEqual(
            Data(SHA256.hash(data: wal)).hex,
            "223c2546de93af522512c87b8843e03fbbe4c46a8dfa3ff8c12aea6197bcf454"
        )
        let replay = try LocalStoragePeopleProvider.parseWAL(wal)
        XCTAssertEqual(replay.committedPageCount, 2)
        XCTAssertEqual(replay.pages[1], encrypted)
    }

    func testWALOnlyNewestFixIsQueriedFromMemory() async throws {
        let base = try databaseImage(name: "Taylor", latitude: 40.0, timestamp: 100)
        let newest = try databaseImage(name: "Taylor", latitude: 41.25, timestamp: 200)
        let encryptedBase = try encryptedDatabase(base)
        let encryptedNewestPages = try encryptedPages(newest)
        let url = directory.appendingPathComponent("LocalStorage.db")
        try encryptedBase.write(to: url)
        try makeWAL(
            pages: encryptedNewestPages.enumerated().map { (index: $0.offset, body: $0.element) },
            committedPageCount: encryptedNewestPages.count
        ).write(to: URL(fileURLWithPath: url.path + "-wal"))

        let provider = LocalStoragePeopleProvider(candidateURLs: [url])
        let people = try await provider.people(databaseURL: url, key: key)

        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people.first?.serverIdentifier, "server-taylor")
        XCTAssertEqual(people.first?.displayName, "Taylor")
        XCTAssertEqual(people.first?.fix.latitude, 41.25)
        XCTAssertEqual(
            people.first?.fix.timestamp,
            Date(timeIntervalSinceReferenceDate: 200)
        )
        XCTAssertEqual(people.first?.fix.locationLabel, "Home")
    }

    func testDisappearingWALRetriesAsAConsistentMainDatabaseSnapshot() async throws {
        let base = try databaseImage(name: "Taylor", latitude: 40, timestamp: 100)
        let newest = try databaseImage(name: "Taylor", latitude: 41, timestamp: 200)
        let url = directory.appendingPathComponent("LocalStorage.db")
        try encryptedDatabase(base).write(to: url)
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let pages = try encryptedPages(newest)
        try makeWAL(
            pages: pages.enumerated().map { (index: $0.offset, body: $0.element) },
            committedPageCount: pages.count
        ).write(to: walURL)
        let once = LockedOnce()
        let provider = LocalStoragePeopleProvider(candidateURLs: [url]) { observed in
            once.perform { try? FileManager.default.removeItem(at: observed) }
        }

        let people = try await provider.people(databaseURL: url, key: key)

        XCTAssertEqual(once.count, 1)
        XCTAssertEqual(people.first?.fix.latitude, 40)
    }

    func testReplacedWALRetriesInsteadOfMergingDifferentFileGenerations() async throws {
        let base = try databaseImage(name: "Taylor", latitude: 40, timestamp: 100)
        let first = try databaseImage(name: "Taylor", latitude: 41, timestamp: 200)
        let replacement = try databaseImage(name: "Taylor", latitude: 42, timestamp: 300)
        let url = directory.appendingPathComponent("LocalStorage.db")
        try encryptedDatabase(base).write(to: url)
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let firstPages = try encryptedPages(first)
        try makeWAL(
            pages: firstPages.enumerated().map { (index: $0.offset, body: $0.element) },
            committedPageCount: firstPages.count
        ).write(to: walURL)
        let replacementPages = try encryptedPages(replacement)
        let replacementWAL = makeWAL(
            pages: replacementPages.enumerated().map { (index: $0.offset, body: $0.element) },
            committedPageCount: replacementPages.count
        )
        let once = LockedOnce()
        let provider = LocalStoragePeopleProvider(candidateURLs: [url]) { observed in
            once.perform { try? replacementWAL.write(to: observed, options: .atomic) }
        }

        let people = try await provider.people(databaseURL: url, key: key)

        XCTAssertEqual(once.count, 1)
        XCTAssertEqual(people.first?.fix.latitude, 42)
    }

    func testWrongAndWrongLengthKeysAreDistinct() async throws {
        let url = directory.appendingPathComponent("LocalStorage.db")
        try encryptedDatabase(databaseImage()).write(to: url)
        let provider = LocalStoragePeopleProvider(candidateURLs: [url])

        do {
            _ = try await provider.people(databaseURL: url, key: Data(count: 31))
            XCTFail("Expected invalid key length")
        } catch let error as LocalStoragePeopleError {
            XCTAssertEqual(error, .invalidKeyLength)
        }
        do {
            _ = try await provider.people(databaseURL: url, key: Data(repeating: 0xFF, count: 32))
            XCTFail("Expected incorrect key")
        } catch let error as LocalStoragePeopleError {
            XCTAssertEqual(error, .incorrectKey)
        }
    }

    func testOversizedDatabaseHasCompatibilityError() async throws {
        let url = directory.appendingPathComponent("LocalStorage.db")
        try encryptedDatabase(databaseImage()).write(to: url)
        let provider = LocalStoragePeopleProvider(candidateURLs: [url], maximumBytes: pageSize)
        do {
            _ = try await provider.people(databaseURL: url, key: key)
            XCTFail("Expected size bound")
        } catch let error as LocalStoragePeopleError {
            XCTAssertEqual(error, .oversizedDatabase(limitBytes: pageSize))
            XCTAssertFalse(error.localizedDescription.contains(url.path))
        }
    }

    func testUnsupportedSchemaDoesNotMasqueradeAsEmpty() async throws {
        let image = try databaseImage(schemaOnly: true)
        let url = directory.appendingPathComponent("LocalStorage.db")
        try encryptedDatabase(image).write(to: url)
        let provider = LocalStoragePeopleProvider(candidateURLs: [url])
        do {
            _ = try await provider.people(databaseURL: url, key: key)
            XCTFail("Expected unsupported schema")
        } catch let error as LocalStoragePeopleError {
            XCTAssertEqual(error, .unsupportedSchema)
        }
    }

    func testWALIgnoresBadChecksumTornTailAndRefusesAnOutOfRangePage() async throws {
        let body = Data(repeating: 0xA5, count: pageSize)
        var badChecksum = makeWAL(pages: [(0, body)], committedPageCount: 1)
        badChecksum[60] ^= 0x01
        XCTAssertTrue(try LocalStoragePeopleProvider.parseWAL(badChecksum).pages.isEmpty)

        let torn = Data(makeWAL(pages: [(0, body)], committedPageCount: 1).dropLast(17))
        let tornReplay = try LocalStoragePeopleProvider.parseWAL(torn)
        XCTAssertTrue(tornReplay.pages.isEmpty)

        let hugePage = makeWAL(pages: [(999_999, body)], committedPageCount: 1_000_000)
        let replay = try LocalStoragePeopleProvider.parseWAL(hugePage)
        XCTAssertEqual(Array(replay.pages.keys), [999_999])
        // The merge refuses a page far past the database's size before allocating it.
        let url = directory.appendingPathComponent("LocalStorage.db")
        try encryptedDatabase(databaseImage()).write(to: url)
        try hugePage.write(to: URL(fileURLWithPath: url.path + "-wal"))
        do {
            _ = try await LocalStoragePeopleProvider(candidateURLs: [url]).people(databaseURL: url, key: key)
            XCTFail("Expected the out-of-range page to be refused")
        } catch {
            XCTAssertEqual(error as? LocalStoragePeopleError, .malformedDatabase)
        }
    }

    func testWALReplayStopsAtFirstStaleOrCorruptFrame() throws {
        let first = Data(repeating: 0x11, count: pageSize)
        let second = Data(repeating: 0x22, count: pageSize)
        let committed = try LocalStoragePeopleProvider.parseWAL(
            makeWAL(pages: [(0, first)], committedPageCount: 1)
        )
        let frameSize = 24 + pageSize
        let secondFrame = 32 + frameSize

        // makeWAL marks only the last frame as a commit, so build the
        // two-commit file by appending a second commit frame whose checksum
        // continues from the first frame's.
        var twoCommits = makeWAL(pages: [(0, first)], committedPageCount: 1)
        var checked = be(2)
        checked.append(be(2))
        checked.append(second)
        let chained = checksum(checked, initial: (readBE(twoCommits, 32 + 16), readBE(twoCommits, 32 + 20)))
        twoCommits.append(checked.prefix(8))
        [0xAAAA_1111, 0xBBBB_2222, chained.0, chained.1].forEach { twoCommits.append(be($0)) }
        twoCommits.append(second)
        XCTAssertEqual(try LocalStoragePeopleProvider.parseWAL(twoCommits).pages.count, 2)

        var staleSalt = twoCommits
        staleSalt[secondFrame + 8] ^= 0xFF
        XCTAssertEqual(try LocalStoragePeopleProvider.parseWAL(staleSalt), committed)

        var badChecksum = twoCommits
        badChecksum[secondFrame + 24] ^= 0x01
        XCTAssertEqual(try LocalStoragePeopleProvider.parseWAL(badChecksum), committed)

        var zeroPage = twoCommits
        zeroPage.replaceSubrange(secondFrame ..< secondFrame + 4, with: Data(count: 4))
        XCTAssertEqual(try LocalStoragePeopleProvider.parseWAL(zeroPage), committed)
    }

    // MARK: Synthetic fixtures

    private func databaseImage(
        name: String = "Taylor",
        latitude: Double = 40.0,
        timestamp: Double = 100,
        schemaOnly: Bool = false
    ) throws -> Data {
        let url = directory.appendingPathComponent("plain-\(UUID().uuidString).sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let database = handle else {
            throw NSError(domain: "fixture", code: 1)
        }
        defer {
            if let handle { sqlite3_close(handle) }
            try? FileManager.default.removeItem(at: url)
        }
        if schemaOnly {
            XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE unrelated(value TEXT)", nil, nil, nil), SQLITE_OK)
        } else {
            let schema = """
                CREATE TABLE friends(
                    handlePrettyName TEXT, handleContactIdentifier TEXT,
                    handleIdentifier TEXT, handleServerIdentifier TEXT
                );
                CREATE TABLE secureLocations(serverUserID TEXT, value BLOB);
                """
            XCTAssertEqual(sqlite3_exec(database, schema, nil, nil, nil), SQLITE_OK)
            let plist: [String: Any] = [
                "latitude": latitude,
                "longitude": -73.5,
                "horizontalAccuracy": 12.0,
                "timestamp": timestamp,
                "locationLabel": "_$!<home>!$_",
            ]
            let blob = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .binary,
                options: 0
            )
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    database,
                    "INSERT INTO friends VALUES(?, NULL, NULL, 'server-taylor')",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT_TEST)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    database,
                    "INSERT INTO secureLocations VALUES('server-taylor', ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            _ = blob.withUnsafeBytes {
                sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT_TEST)
            }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        handle = nil
        return try Data(contentsOf: url)
    }

    private func encryptedDatabase(_ plaintext: Data) throws -> Data {
        var result = Data()
        for page in try encryptedPages(plaintext) { result.append(page) }
        return result
    }

    private func encryptedPages(_ plaintext: Data) throws -> [Data] {
        XCTAssertTrue(plaintext.count.isMultiple(of: pageSize))
        return try stride(from: 0, to: plaintext.count, by: pageSize).enumerated().map {
            index,
            offset in
            let page = Data(plaintext[offset ..< (offset + pageSize)])
            return try encryptedPage(
                plaintext: page.prefix(contentSize),
                pageIndex: index,
                key: key,
                reserved: page.suffix(12)
            )
        }
    }

    private func encryptedPage(
        plaintext: Data,
        pageIndex: Int,
        key: Data,
        reserved: Data
    ) throws -> Data {
        var iv = Data(count: 16)
        var number = UInt32(pageIndex + 1).littleEndian
        withUnsafeBytes(of: &number) { iv.replaceSubrange(0 ..< 4, with: $0) }
        iv.replaceSubrange(4 ..< 16, with: reserved)
        let zeros = Data(count: pageSize)
        var stream = Data(count: pageSize)
        var length = 0
        let status = stream.withUnsafeMutableBytes { output in
            iv.withUnsafeBytes { iv in
                key.withUnsafeBytes { key in
                    zeros.withUnsafeBytes { input in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            0,
                            key.baseAddress,
                            key.count,
                            iv.baseAddress,
                            input.baseAddress,
                            input.count,
                            output.baseAddress,
                            output.count,
                            &length
                        )
                    }
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        var encrypted = Data(count: contentSize)
        for index in 0 ..< contentSize { encrypted[index] = plaintext[index] ^ stream[index] }
        if pageIndex == 0 { encrypted.replaceSubrange(16 ..< 24, with: plaintext[16 ..< 24]) }
        encrypted.append(reserved)
        return encrypted
    }

    private func makeWAL(
        pages: [(index: Int, body: Data)],
        committedPageCount: Int
    ) -> Data {
        var header = Data()
        [0x377F_0683, 3_007_000, UInt32(pageSize), 1, 0xAAAA_1111, 0xBBBB_2222]
            .forEach { header.append(be($0)) }
        var checksum = checksum(header)
        header.append(be(checksum.0))
        header.append(be(checksum.1))
        var wal = header
        for (offset, entry) in pages.enumerated() {
            var frame = Data()
            frame.append(be(UInt32(entry.index + 1)))
            frame.append(be(offset == pages.count - 1 ? UInt32(committedPageCount) : 0))
            frame.append(be(0xAAAA_1111))
            frame.append(be(0xBBBB_2222))
            var checked = Data(frame.prefix(8))
            checked.append(entry.body)
            checksum = self.checksum(checked, initial: checksum)
            frame.append(be(checksum.0))
            frame.append(be(checksum.1))
            frame.append(entry.body)
            wal.append(frame)
        }
        return wal
    }

    private func checksum(_ data: Data, initial: (UInt32, UInt32) = (0, 0)) -> (UInt32, UInt32) {
        var first = initial.0
        var second = initial.1
        for offset in stride(from: 0, to: data.count, by: 8) {
            first &+= readBE(data, offset) &+ second
            second &+= readBE(data, offset + 4) &+ first
        }
        return (first, second)
    }

    private func readBE(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian }
    }

    private func be(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}

private final class LockedOnce: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0

    func perform(_ action: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard count == 0 else { return }
        count += 1
        action()
    }
}

private let SQLITE_TRANSIENT_TEST = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private extension DataProtocol {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
