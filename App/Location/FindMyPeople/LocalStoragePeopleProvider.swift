import CommonCrypto
import Foundation
import OSLog

private let log = Logger.service("location.people.provider")

struct LocalStoragePersonFix: Sendable, Equatable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double?
    let timestamp: Date?
    let verticalAccuracy: Double?
    let altitude: Double?
    let speed: Double?
    let course: Double?
    let motionActivityState: Int?
    let locationLabel: String?
}

struct LocalStoragePerson: Sendable, Equatable {
    let serverIdentifier: String
    let displayName: String
    let fix: LocalStoragePersonFix
    let source: String
}

enum LocalStoragePeopleError: Swift.Error, ClientFacingError, Equatable {
    case databaseNotFound
    case databaseInaccessible
    case invalidKeyLength
    case incorrectKey
    case inconsistentSnapshot
    case oversizedDatabase(limitBytes: Int)
    case unsupportedSchema
    case malformedDatabase
    case memoryOnlySQLiteUnavailable

    var errorDescription: String? {
        switch self {
        case .databaseNotFound:
            return "The Find My People database is not available. Open Find My and try again."
        case .databaseInaccessible:
            return "Full Disk Access is required to read Find My People."
        case .invalidKeyLength:
            return "The Find My People key is invalid. Import a 32-byte key."
        case .incorrectKey:
            return "The Find My People key no longer matches this database. Run setup again."
        case .inconsistentSnapshot:
            return "Find My changed its People database during the read. Try again."
        case .oversizedDatabase(let limitBytes):
            return "The Find My People database exceeds the supported \(limitBytes)-byte limit."
        case .unsupportedSchema:
            return "This macOS Find My People database format is not supported yet."
        case .malformedDatabase:
            return "The Find My People database could not be read safely."
        case .memoryOnlySQLiteUnavailable:
            return "This macOS build cannot query Find My People without writing decrypted data."
        }
    }
}

/// Read-only decoder for findmylocateagent's encrypted People database.
///
/// The page codec and WAL layout are adapted from FindMySyncPlus commit
/// 0b8a5fbbeb96dc90313a09a946df22c0a67190bd (MIT). iMCP adds stable raw-file
/// snapshots, WAL checksum validation, strict size bounds, and memory-only
/// SQLite deserialization. No decrypted page is written to disk.
actor LocalStoragePeopleProvider {
    static let defaultMaximumBytes = 64 * 1024 * 1024

    static let groupContainerRelativePath =
        "Library/Group Containers/group.com.apple.findmy.findmylocateagent/Library/Application Support/LocalStorage.db"
    static let confinementSubPath = "com.apple.findmy.findmylocateagent/LocalStorage.db"

    private static let pageSize = 4096
    private static let contentSize = 4084
    private static let reservedOffset = 4084
    private static let sqliteMagic = Data("SQLite format 3\0".utf8)
    private static let maximumSnapshotAttempts = 3

    private let candidateURLs: [URL]
    private let maximumBytes: Int
    private let didObserveWAL: @Sendable (URL) -> Void

    init(
        candidateURLs: [URL] = LocalStoragePeopleProvider.defaultCandidateURLs(),
        maximumBytes: Int = LocalStoragePeopleProvider.defaultMaximumBytes,
        didObserveWAL: @escaping @Sendable (URL) -> Void = { _ in }
    ) {
        self.candidateURLs = candidateURLs
        self.maximumBytes = maximumBytes
        self.didObserveWAL = didObserveWAL
    }

    static func defaultCandidateURLs() -> [URL] {
        var urls: [URL] = []
        var buffer = [CChar](repeating: 0, count: 1024)
        let length = confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count)
        if length > 0, length <= buffer.count {
            let path = String(cString: buffer)
            if !path.isEmpty {
                urls.append(
                    URL(fileURLWithPath: path, isDirectory: true)
                        .appendingPathComponent(confinementSubPath)
                )
            }
        }
        urls.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(groupContainerRelativePath)
        )
        return urls
    }

    func people(key: Data) throws -> [LocalStoragePerson] {
        guard key.count == LocalStorageKeyStorage.secretLength else { throw LocalStoragePeopleError.invalidKeyLength }

        var sawExistingCandidate = false
        var sawPermissionFailure = false
        var valid: [(URL, Date)] = []
        for url in candidateURLs {
            do {
                let candidate = try Self.readCandidatePrefix(url)
                sawExistingCandidate = true
                let page = try Self.decryptPage(candidate.page, pageIndex: 0, key: key)
                guard page.prefix(Self.sqliteMagic.count) == Self.sqliteMagic else { continue }
                valid.append((url, candidate.modified))
            } catch LocalStoragePeopleError.databaseNotFound {
                continue
            } catch LocalStoragePeopleError.databaseInaccessible {
                sawPermissionFailure = true
            } catch {
                // Not a database this key opens. Another candidate may be.
                continue
            }
        }

        guard let url = valid.max(by: { $0.1 < $1.1 })?.0 else {
            if sawPermissionFailure { throw LocalStoragePeopleError.databaseInaccessible }
            if sawExistingCandidate { throw LocalStoragePeopleError.incorrectKey }
            throw LocalStoragePeopleError.databaseNotFound
        }
        return try people(databaseURL: url, key: key)
    }

    func people(databaseURL: URL, key: Data) throws -> [LocalStoragePerson] {
        guard key.count == LocalStorageKeyStorage.secretLength else { throw LocalStoragePeopleError.invalidKeyLength }
        var lastError: LocalStoragePeopleError = .inconsistentSnapshot
        for _ in 0 ..< Self.maximumSnapshotAttempts {
            do {
                let snapshot = try capture(databaseURL: databaseURL)
                return try Self.decode(database: snapshot.database, wal: snapshot.wal, key: key)
            } catch let error as LocalStoragePeopleError {
                lastError = error
                guard error == .inconsistentSnapshot else { throw error }
            }
        }
        throw lastError
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
    }

    private struct RawSnapshot {
        let database: Data
        let wal: Data?
    }

    private func capture(databaseURL: URL) throws -> RawSnapshot {
        let database = try Self.openAndRead(databaseURL, maximumBytes: maximumBytes)
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let walBefore = Self.pathIdentity(walURL)
        let wal: (Data, FileIdentity)?
        if let walBefore {
            didObserveWAL(walURL)
            do {
                let opened = try Self.openAndRead(walURL, maximumBytes: maximumBytes)
                guard opened.identity == walBefore else {
                    throw LocalStoragePeopleError.inconsistentSnapshot
                }
                wal = opened
            } catch LocalStoragePeopleError.databaseNotFound {
                // A checkpoint may remove the WAL between observing and
                // opening it. That is a changing snapshot, not a missing main
                // database, and must use the bounded snapshot retry path.
                throw LocalStoragePeopleError.inconsistentSnapshot
            }
        } else {
            wal = nil
        }

        guard database.identity == Self.pathIdentity(databaseURL),
            walBefore == Self.pathIdentity(walURL),
            wal?.1 == walBefore
        else {
            throw LocalStoragePeopleError.inconsistentSnapshot
        }
        return RawSnapshot(database: database.data, wal: wal?.0)
    }

    private static func openAndRead(_ url: URL, maximumBytes: Int) throws -> (data: Data, identity: FileIdentity) {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: throw LocalStoragePeopleError.databaseNotFound
            case EACCES, EPERM: throw LocalStoragePeopleError.databaseInaccessible
            default: throw LocalStoragePeopleError.malformedDatabase
            }
        }
        defer { close(descriptor) }
        let before = try identity(descriptor)
        guard before.size <= maximumBytes else {
            throw LocalStoragePeopleError.oversizedDatabase(limitBytes: maximumBytes)
        }
        var data = Data(count: before.size)
        let readCount = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var total = 0
            while total < buffer.count {
                let count = pread(descriptor, base.advanced(by: total), buffer.count - total, off_t(total))
                if count < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                if count == 0 { break }
                total += count
            }
            return total
        }
        guard readCount == before.size else { throw LocalStoragePeopleError.inconsistentSnapshot }
        let after = try identity(descriptor)
        guard before == after else { throw LocalStoragePeopleError.inconsistentSnapshot }
        return (data, before)
    }

    private static func readCandidatePrefix(_ url: URL) throws -> (page: Data, modified: Date) {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: throw LocalStoragePeopleError.databaseNotFound
            case EACCES, EPERM: throw LocalStoragePeopleError.databaseInaccessible
            default: throw LocalStoragePeopleError.malformedDatabase
            }
        }
        defer { close(descriptor) }
        let identity = try identity(descriptor)
        guard identity.size >= pageSize else { throw LocalStoragePeopleError.malformedDatabase }
        var page = Data(count: pageSize)
        let actual = page.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, pageSize, 0) }
        guard actual == pageSize else { throw LocalStoragePeopleError.malformedDatabase }
        let modified = Date(
            timeIntervalSince1970: TimeInterval(identity.modifiedSeconds)
                + TimeInterval(identity.modifiedNanoseconds) / 1_000_000_000
        )
        return (page, modified)
    }

    private static func identity(_ descriptor: Int32) throws -> FileIdentity {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw LocalStoragePeopleError.malformedDatabase }
        return FileIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            size: Int(value.st_size),
            modifiedSeconds: Int(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int(value.st_mtimespec.tv_nsec)
        )
    }

    private static func pathIdentity(_ url: URL) -> FileIdentity? {
        var value = stat()
        guard lstat(url.path, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG else { return nil }
        return FileIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            size: Int(value.st_size),
            modifiedSeconds: Int(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int(value.st_mtimespec.tv_nsec)
        )
    }

    // MARK: Page codec

    static func decryptPage(_ encryptedPage: Data, pageIndex: Int, key: Data) throws -> Data {
        guard key.count == LocalStorageKeyStorage.secretLength else { throw LocalStoragePeopleError.invalidKeyLength }
        guard encryptedPage.count == pageSize else { throw LocalStoragePeopleError.malformedDatabase }
        let pageNumber = UInt32(pageIndex + 1)
        var iv = Data(count: kCCBlockSizeAES128)
        withUnsafeBytes(of: pageNumber.littleEndian) { iv.replaceSubrange(0 ..< 4, with: $0) }
        iv.replaceSubrange(4 ..< 16, with: encryptedPage[reservedOffset ..< pageSize])

        let zeros = Data(count: pageSize)
        var keystream = Data(count: pageSize)
        var outputLength = 0
        let status = keystream.withUnsafeMutableBytes { output in
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
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess, outputLength == pageSize else {
            throw LocalStoragePeopleError.malformedDatabase
        }
        var plaintext = Data(count: contentSize)
        plaintext.withUnsafeMutableBytes { output in
            encryptedPage.withUnsafeBytes { encrypted in
                keystream.withUnsafeBytes { stream in
                    let output = output.bindMemory(to: UInt8.self)
                    let encrypted = encrypted.bindMemory(to: UInt8.self)
                    let stream = stream.bindMemory(to: UInt8.self)
                    for index in 0 ..< contentSize { output[index] = encrypted[index] ^ stream[index] }
                }
            }
        }
        if pageIndex == 0 { plaintext.replaceSubrange(16 ..< 24, with: encryptedPage[16 ..< 24]) }
        return plaintext
    }

    private static func decode(database: Data, wal: Data?, key: Data) throws -> [LocalStoragePerson] {
        guard !database.isEmpty, database.count.isMultiple(of: pageSize) else {
            throw LocalStoragePeopleError.malformedDatabase
        }
        var encryptedPages = stride(from: 0, to: database.count, by: pageSize).map {
            Data(database[$0 ..< ($0 + pageSize)])
        }
        if let wal, !wal.isEmpty {
            let replay = try parseWAL(wal)
            let maximumPageCount = encryptedPages.count + replay.pages.count
            for (index, page) in replay.pages.sorted(by: { $0.key < $1.key }) {
                guard index >= 0, index < maximumPageCount else {
                    throw LocalStoragePeopleError.malformedDatabase
                }
                while encryptedPages.count <= index { encryptedPages.append(Data(count: pageSize)) }
                encryptedPages[index] = page
            }
            if let committedPageCount = replay.committedPageCount {
                guard committedPageCount > 0, committedPageCount <= maximumPageCount else {
                    throw LocalStoragePeopleError.malformedDatabase
                }
                if encryptedPages.count > committedPageCount {
                    encryptedPages.removeLast(encryptedPages.count - committedPageCount)
                }
            }
        }
        let first = try decryptPage(encryptedPages[0], pageIndex: 0, key: key)
        guard first.prefix(sqliteMagic.count) == sqliteMagic else {
            throw LocalStoragePeopleError.incorrectKey
        }

        var plaintext = Data()
        plaintext.reserveCapacity(encryptedPages.count * pageSize)
        for (index, page) in encryptedPages.enumerated() {
            plaintext.append(try decryptPage(page, pageIndex: index, key: key))
            plaintext.append(page[reservedOffset ..< pageSize])
        }
        return try query(plaintext)
    }

    struct WALReplay: Equatable {
        let pages: [Int: Data]
        let committedPageCount: Int?
    }

    static func parseWAL(_ data: Data) throws -> WALReplay {
        let headerSize = 32
        let frameHeaderSize = 24
        let frameSize = frameHeaderSize + pageSize
        guard data.count >= headerSize else { throw LocalStoragePeopleError.malformedDatabase }
        let magic = readBE32(data, at: 0)
        guard magic == 0x377F_0682 || magic == 0x377F_0683,
            readBE32(data, at: 8) == UInt32(pageSize)
        else { throw LocalStoragePeopleError.malformedDatabase }
        let nativeChecksums = magic == 0x377F_0682
        var checksum = walChecksum(data[0 ..< 24], initial: (0, 0), native: nativeChecksums)
        guard checksum.0 == readBE32(data, at: 24), checksum.1 == readBE32(data, at: 28) else {
            throw LocalStoragePeopleError.malformedDatabase
        }
        let salt1 = readBE32(data, at: 16)
        let salt2 = readBE32(data, at: 20)
        let completeFrames = (data.count - headerSize) / frameSize
        var frames: [(page: Int, body: Data, commitSize: Int)] = []
        var lastCommit = -1
        // SQLite recovery stops at the first frame with a zero page number,
        // stale salts, or a bad cumulative checksum; frames left over from
        // before a WAL restart are normal, not corruption.
        for index in 0 ..< completeFrames {
            let offset = headerSize + index * frameSize
            let pageNumber = readBE32(data, at: offset)
            let commitSize = readBE32(data, at: offset + 4)
            guard pageNumber > 0,
                readBE32(data, at: offset + 8) == salt1,
                readBE32(data, at: offset + 12) == salt2
            else { break }
            let bodyStart = offset + frameHeaderSize
            let body = Data(data[bodyStart ..< (bodyStart + pageSize)])
            var checksumInput = Data(data[offset ..< (offset + 8)])
            checksumInput.append(body)
            checksum = walChecksum(checksumInput, initial: checksum, native: nativeChecksums)
            guard checksum.0 == readBE32(data, at: offset + 16),
                checksum.1 == readBE32(data, at: offset + 20)
            else { break }
            frames.append((Int(pageNumber) - 1, body, Int(commitSize)))
            if commitSize != 0 { lastCommit = index }
        }
        guard lastCommit >= 0 else { return WALReplay(pages: [:], committedPageCount: nil) }
        var pages: [Int: Data] = [:]
        for frame in frames[0 ... lastCommit] { pages[frame.page] = frame.body }
        return WALReplay(pages: pages, committedPageCount: frames[lastCommit].commitSize)
    }

    private static func walChecksum(
        _ bytes: Data.SubSequence,
        initial: (UInt32, UInt32),
        native: Bool
    ) -> (UInt32, UInt32) {
        var first = initial.0
        var second = initial.1
        var offset = bytes.startIndex
        while offset + 8 <= bytes.endIndex {
            let left = read32(bytes, at: offset, native: native)
            let right = read32(bytes, at: offset + 4, native: native)
            first &+= left &+ second
            second &+= right &+ first
            offset += 8
        }
        return (first, second)
    }

    private static func read32(_ data: Data.SubSequence, at offset: Int, native: Bool) -> UInt32 {
        let value = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset - data.startIndex, as: UInt32.self)
        }
        return native ? value : value.bigEndian
    }

    private static func readBE32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian }
    }

    // MARK: Memory-only SQLite

    private static let requiredColumns: [String: Set<String>] = [
        "friends": ["handlePrettyName", "handleContactIdentifier", "handleIdentifier", "handleServerIdentifier"],
        "secureLocations": ["serverUserID", "value"],
    ]

    private static func query(_ image: Data) throws -> [LocalStoragePerson] {
        let database: ReadOnlySQLite
        do {
            database = try ReadOnlySQLite(deserializing: image)
        } catch {
            throw LocalStoragePeopleError.memoryOnlySQLiteUnavailable
        }
        do {
            for (table, columns) in requiredColumns {
                let present = Set(try database.rows("PRAGMA table_info(\(table))") { $0.text(1) })
                guard present.isSuperset(of: columns) else { throw LocalStoragePeopleError.unsupportedSchema }
            }
            // A row without a readable position is skipped, not fatal: one
            // friend's odd record must not hide the rest. Only the count is
            // logged, so a schema change shows up as a number, never as content.
            var unreadable = 0
            defer {
                if unreadable > 0 { log.notice("Skipped \(unreadable) local People rows with no readable position") }
            }
            let people = try database.rows(
                """
                SELECT f.handlePrettyName, f.handleContactIdentifier, f.handleIdentifier,
                       f.handleServerIdentifier, sl.value
                FROM friends f JOIN secureLocations sl
                  ON f.handleServerIdentifier = sl.serverUserID
                """
            ) { row in
                let person = person(from: row)
                if person == nil { unreadable += 1 }
                return person
            }
            return people.sorted {
                let order = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                return order == .orderedSame ? $0.serverIdentifier < $1.serverIdentifier : order == .orderedAscending
            }
        } catch is SQLiteQueryError {
            throw LocalStoragePeopleError.unsupportedSchema
        }
    }

    private static func person(from row: SQLiteRow) -> LocalStoragePerson? {
        guard let identifier = row.text(3), !identifier.isEmpty,
            let value = row.blob(4), !value.isEmpty,
            let dictionary = try? PropertyListSerialization.propertyList(from: value, format: nil) as? [String: Any],
            let latitude = number(dictionary["latitude"]),
            let longitude = number(dictionary["longitude"])
        else { return nil }
        let timestamp: Date?
        if let date = dictionary["timestamp"] as? Date {
            timestamp = date
        } else if let seconds = number(dictionary["timestamp"]) {
            timestamp = Date(timeIntervalSinceReferenceDate: seconds)
        } else {
            timestamp = nil
        }
        let name =
            [row.text(0), row.text(1), row.text(2)]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "Unknown"
        return LocalStoragePerson(
            serverIdentifier: identifier,
            displayName: name,
            fix: LocalStoragePersonFix(
                latitude: latitude,
                longitude: longitude,
                horizontalAccuracy: number(dictionary["horizontalAccuracy"]),
                timestamp: timestamp,
                verticalAccuracy: number(dictionary["verticalAccuracy"]),
                altitude: number(dictionary["altitude"]),
                speed: number(dictionary["speed"]),
                course: number(dictionary["course"]),
                motionActivityState: number(dictionary["motionActivityState"]).map(Int.init),
                locationLabel: decodedLabel(dictionary["locationLabel"] as? String)
            ),
            source: "findMyPeopleLocalStorage"
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        return value as? Double
    }

    private static func decodedLabel(_ value: String?) -> String? {
        guard let value, value != "$null" else { return nil }
        if value.hasPrefix("_$!<"), value.hasSuffix(">!$_"), value.count > 8 {
            return String(value.dropFirst(4).dropLast(4)).capitalized
        }
        return value.isEmpty ? nil : value
    }
}
