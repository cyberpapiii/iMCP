import Darwin
import Foundation

enum NotificationRecordSource: String, Equatable {
    case mac
    case iphone
}

enum NotificationTimestampEvidence: String, Equatable {
    case delivered
    case created
}

enum NotificationSourceStatus: String, Equatable {
    case available
    case degraded
    case unavailable
    case denied
    case changedDuringRead
    case malformed
}

struct NotificationSourceOutcome: Equatable {
    let source: NotificationRecordSource
    let status: NotificationSourceStatus
    let isTruncated: Bool
    /// Records this source returned whose free text could not be decoded. They
    /// are present with evidence, unlike the records `degraded` says were skipped.
    var damagedTextRecordCount = 0
}

struct NotificationSourceResult: Equatable {
    let records: [NormalizedNotificationRecord]
    let outcome: NotificationSourceOutcome
}

struct NormalizedNotificationRecord: Equatable {
    let source: NotificationRecordSource
    let nativeIdentifier: String
    let occurredAt: Date
    let timestampEvidence: NotificationTimestampEvidence
    let appIdentifier: String?
    let title: String?
    let subtitle: String?
    let body: String?
    var damagedText: [DamagedNotificationText] = []

    var id: String {
        switch source {
        case .mac:
            return "notification:\(nativeIdentifier)"
        case .iphone:
            return "notification:iphone:\(appIdentifier ?? "unknown"):\(nativeIdentifier)"
        }
    }

    /// The one order notifications are listed in: newest first, ties by `id`.
    static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.occurredAt == rhs.occurredAt ? lhs.id < rhs.id : lhs.occurredAt > rhs.occurredAt
    }
}

/// Bounds on what one fetch reads from the iPhone archives.
enum RemoteNotificationLimits {
    static let maximumFileBytes = 8 * 1_024 * 1_024
    static let maximumRecords = 25_000
}

/// A free-text field whose archived UTF-16 is invalid, such as a lone
/// surrogate. The field's text is nil; these are its original big-endian code
/// units, kept as evidence and never repaired or guessed.
struct DamagedNotificationText: Equatable {
    enum Field: String {
        case title
        case subtitle
        case body
    }

    let field: Field
    let utf16BigEndian: Data
}

enum RemoteNotificationStoreError: Error, Equatable {
    case malformed
    case exceededLimit
    case invalidMappedDirectory
    case unavailable
    case denied
    case changedDuringRead
}

struct RemoteNotificationArchiveDecoder {
    struct Limits {
        var maximumFileBytes = RemoteNotificationLimits.maximumFileBytes
        var maximumRecords = RemoteNotificationLimits.maximumRecords
        var maximumGraphDepth = 64
        var maximumObjects = 250_000
    }

    let limits: Limits

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    func decodeLibraryMappings(_ data: Data) throws -> [String: String] {
        let archive = try graph(from: data)
        let root = try archive.rootDictionary(maximumDepth: limits.maximumGraphDepth)
        var mappings: [String: String] = [:]
        for (key, value) in root {
            guard let directory = try archive.string(value, maximumDepth: limits.maximumGraphDepth) else {
                throw RemoteNotificationStoreError.malformed
            }
            guard RemoteNotificationFileReader.isValidMappedDirectory(directory) else {
                throw RemoteNotificationStoreError.invalidMappedDirectory
            }
            mappings[key] = directory
        }
        return mappings
    }

    func decodeDeliveredNotifications(
        _ data: Data,
        bundleIdentifier: String
    ) throws -> [NormalizedNotificationRecord] {
        guard !bundleIdentifier.isEmpty else { throw RemoteNotificationStoreError.malformed }
        let archive = try graph(from: data)
        let objects = try archive.rootArray(maximumDepth: limits.maximumGraphDepth)
        guard objects.count <= limits.maximumRecords else { throw RemoteNotificationStoreError.exceededLimit }

        var identifiers: Set<String> = []
        return try objects.map { object in
            let fields = try archive.dictionary(object, maximumDepth: limits.maximumGraphDepth)
            guard
                let nativeIdentifier = try archive.string(
                    fields["AppNotificationIdentifier"],
                    maximumDepth: limits.maximumGraphDepth
                ),
                !nativeIdentifier.isEmpty,
                let createdAt = try archive.date(
                    fields["AppNotificationCreationDate"],
                    maximumDepth: limits.maximumGraphDepth
                )
            else {
                throw RemoteNotificationStoreError.malformed
            }
            guard identifiers.insert(nativeIdentifier).inserted else {
                throw RemoteNotificationStoreError.malformed
            }

            let title = try archive.freeText(
                fields["AppNotificationTitle"],
                field: .title,
                maximumDepth: limits.maximumGraphDepth
            )
            let subtitle = try archive.freeText(
                fields["AppNotificationSubtitle"],
                field: .subtitle,
                maximumDepth: limits.maximumGraphDepth
            )
            let body = try archive.freeText(
                fields["AppNotificationMessage"],
                field: .body,
                maximumDepth: limits.maximumGraphDepth
            )
            return NormalizedNotificationRecord(
                source: .iphone,
                nativeIdentifier: nativeIdentifier,
                occurredAt: createdAt,
                timestampEvidence: .created,
                appIdentifier: bundleIdentifier,
                title: title?.text,
                subtitle: subtitle?.text,
                body: body?.text,
                damagedText: [title, subtitle, body].compactMap { $0?.damage }
            )
        }
    }

    private func graph(from data: Data) throws -> KeyedArchiveGraph {
        guard data.count <= limits.maximumFileBytes else { throw RemoteNotificationStoreError.exceededLimit }
        // Let Foundation reject invalid property-list framing, but traverse the
        // archive's UID graph ourselves instead of instantiating archived classes.
        _ = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        var parser = BinaryPropertyListParser(
            data: data,
            maximumObjects: limits.maximumObjects,
            maximumDepth: limits.maximumGraphDepth
        )
        let root = try parser.parse()
        return try KeyedArchiveGraph(root: root)
    }
}

struct RemoteNotificationFileReader {
    struct LibrarySnapshot {
        let data: Data
        fileprivate let identity: FileIdentity
    }

    static func isValidMappedDirectory(_ name: String) -> Bool {
        name.count == 36 && !name.contains("/") && UUID(uuidString: name) != nil
    }

    static func readLibrarySnapshot(
        below rootURL: URL,
        maximumBytes: Int = RemoteNotificationLimits.maximumFileBytes
    ) throws -> LibrarySnapshot {
        try withLibraryPlist(below: rootURL) { file in
            let data = try read(descriptor: file, maximumBytes: maximumBytes)
            return LibrarySnapshot(data: data, identity: try identity(of: file))
        }
    }

    static func librarySnapshotIsCurrent(_ snapshot: LibrarySnapshot, below rootURL: URL) throws -> Bool {
        try withLibraryPlist(below: rootURL) { file in try identity(of: file) == snapshot.identity }
    }

    static func probeLibraryArchive(
        below rootURL: URL,
        maximumBytes: Int = RemoteNotificationLimits.maximumFileBytes
    ) throws {
        try withLibraryPlist(below: rootURL) { file in
            let identity = try identity(of: file)
            guard (identity.mode & S_IFMT) == S_IFREG else { throw RemoteNotificationStoreError.malformed }
            guard identity.size >= 0, identity.size <= maximumBytes else {
                throw RemoteNotificationStoreError.exceededLimit
            }
        }
    }

    /// `Library.plist` opened below `rootURL` without following a link at
    /// either step, closed again when `body` returns.
    private static func withLibraryPlist<T>(below rootURL: URL, _ body: (Int32) throws -> T) throws -> T {
        let root = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard root >= 0 else { throw accessError() }
        defer { close(root) }
        let file = openat(root, "Library.plist", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard file >= 0 else { throw accessError() }
        defer { close(file) }
        return try body(file)
    }

    static func readDeliveredArchiveIfPresent(
        below rootURL: URL,
        mappedDirectory: String,
        maximumBytes: Int = RemoteNotificationLimits.maximumFileBytes
    ) throws -> Data? {
        guard isValidMappedDirectory(mappedDirectory) else {
            throw RemoteNotificationStoreError.invalidMappedDirectory
        }
        let root = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard root >= 0 else { throw accessError() }
        defer { close(root) }

        let directory = openat(root, mappedDirectory, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else {
            if FileAccessStatus(errno: errno) == .denied { throw RemoteNotificationStoreError.denied }
            throw RemoteNotificationStoreError.malformed
        }
        defer { close(directory) }

        let file = openat(directory, "DeliveredNotifications.plist", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard file >= 0 else {
            if errno == ENOENT { return nil }
            throw accessError()
        }
        defer { close(file) }

        return try read(descriptor: file, maximumBytes: maximumBytes)
    }

    private static func read(descriptor file: Int32, maximumBytes: Int) throws -> Data {
        let before = try identity(of: file)
        guard (before.mode & S_IFMT) == S_IFREG else { throw RemoteNotificationStoreError.malformed }
        guard before.size >= 0, before.size <= maximumBytes else {
            throw RemoteNotificationStoreError.exceededLimit
        }

        var data = Data(count: before.size)
        let count = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < buffer.count {
                let result = pread(file, base.advanced(by: offset), buffer.count - offset, off_t(offset))
                if result < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                if result == 0 { break }
                offset += result
            }
            return offset
        }
        guard count == before.size, before == (try identity(of: file)) else {
            throw RemoteNotificationStoreError.changedDuringRead
        }
        return data
    }

    fileprivate struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let mode: mode_t
    }

    private static func identity(of descriptor: Int32) throws -> FileIdentity {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw RemoteNotificationStoreError.changedDuringRead }
        return FileIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            size: Int(value.st_size),
            modifiedSeconds: Int(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int(value.st_mtimespec.tv_nsec),
            mode: value.st_mode
        )
    }

    private static func accessError() -> RemoteNotificationStoreError {
        let code = errno
        // O_NOFOLLOW refuses a symbolic link with ELOOP.
        if code == ELOOP { return .invalidMappedDirectory }
        switch FileAccessStatus(errno: code) {
        case .denied: return .denied
        case .missing: return .unavailable
        case .notADirectory, .other: return .malformed
        }
    }
}

struct RemoteNotificationSource {
    static let defaultRootURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(
            "Library/Group Containers/group.com.apple.UserNotifications/Library/UserNotifications/Remote/default",
            isDirectory: true
        )

    struct Limits {
        var maximumFileBytes = RemoteNotificationLimits.maximumFileBytes
        var maximumAggregateBytes = 64 * 1_024 * 1_024
        var maximumDirectories = 1_024
        var maximumRecords = RemoteNotificationLimits.maximumRecords
    }

    let rootURL: URL
    let limits: Limits

    init(rootURL: URL = Self.defaultRootURL, limits: Limits = Limits()) {
        self.rootURL = rootURL
        self.limits = limits
    }

    var isReadable: Bool {
        (try? RemoteNotificationFileReader.probeLibraryArchive(
            below: rootURL,
            maximumBytes: limits.maximumFileBytes
        )) != nil
    }

    /// Records in the window, for its app alone when given, newest
    /// first. Two retries nest: an archive that changes while it
    /// is read is read once more (`readDeliveredArchive`), and a `Library.plist`
    /// that changes during the fetch restarts the whole fetch once.
    func fetch(_ window: NotificationWindow) -> NotificationSourceResult {
        for attempt in 0 ... 1 {
            do {
                return try fetchStable(window)
            } catch RemoteNotificationStoreError.changedDuringRead where attempt == 0 {
                continue
            } catch let error as RemoteNotificationStoreError {
                return result(for: error)
            } catch {
                return makeResult([], .malformed, false)
            }
        }
        return makeResult([], .changedDuringRead, false)
    }

    private func fetchStable(_ window: NotificationWindow) throws -> NotificationSourceResult {
        let decoder = RemoteNotificationArchiveDecoder(limits: .init(maximumRecords: limits.maximumRecords))
        let library = try RemoteNotificationFileReader.readLibrarySnapshot(
            below: rootURL,
            maximumBytes: min(limits.maximumFileBytes, limits.maximumAggregateBytes)
        )
        let mappings = try decoder.decodeLibraryMappings(library.data)
        let selected: [(String, String)]
        if let appIdentifier = window.app {
            selected = mappings[appIdentifier].map { [(appIdentifier, $0)] } ?? []
        } else {
            selected = mappings.sorted { $0.key == $1.key ? $0.value < $1.value : $0.key < $1.key }
        }

        var records: [NormalizedNotificationRecord] = []
        var byteCount = library.data.count
        var decodedRecordCount = 0
        var degraded = selected.count > limits.maximumDirectories
        var truncated = degraded
        for (bundleIdentifier, directory) in selected.prefix(max(0, limits.maximumDirectories)) {
            let remainingBytes = limits.maximumAggregateBytes - byteCount
            guard remainingBytes > 0, decodedRecordCount < limits.maximumRecords else {
                degraded = true
                truncated = true
                break
            }
            do {
                guard
                    let data = try readDeliveredArchive(
                        below: rootURL,
                        mappedDirectory: directory,
                        maximumBytes: min(limits.maximumFileBytes, remainingBytes)
                    )
                else { continue }
                byteCount += data.count
                let decoded = try RemoteNotificationArchiveDecoder(
                    limits: .init(maximumRecords: limits.maximumRecords - decodedRecordCount)
                ).decodeDeliveredNotifications(data, bundleIdentifier: bundleIdentifier)
                decodedRecordCount += decoded.count
                records.append(
                    contentsOf: decoded.filter { window.contains($0.occurredAt) && window.matchesSearch($0) }
                )
            } catch RemoteNotificationStoreError.exceededLimit {
                degraded = true
                truncated = true
                continue
            } catch {
                degraded = true
            }
        }
        records.sort(by: NormalizedNotificationRecord.newestFirst)
        guard try RemoteNotificationFileReader.librarySnapshotIsCurrent(library, below: rootURL) else {
            throw RemoteNotificationStoreError.changedDuringRead
        }
        return NotificationSourceResult(
            records: records,
            outcome: NotificationSourceOutcome(
                source: .iphone,
                status: degraded ? .degraded : .available,
                isTruncated: truncated,
                damagedTextRecordCount: records.filter { !$0.damagedText.isEmpty }.count
            )
        )
    }

    private func result(for error: RemoteNotificationStoreError) -> NotificationSourceResult {
        switch error {
        case .denied: return makeResult([], .denied, false)
        case .unavailable: return makeResult([], .unavailable, false)
        case .changedDuringRead: return makeResult([], .changedDuringRead, false)
        case .exceededLimit: return makeResult([], .unavailable, true)
        case .malformed, .invalidMappedDirectory: return makeResult([], .malformed, false)
        }
    }

    private func makeResult(
        _ records: [NormalizedNotificationRecord],
        _ status: NotificationSourceStatus,
        _ truncated: Bool
    ) -> NotificationSourceResult {
        NotificationSourceResult(
            records: records,
            outcome: NotificationSourceOutcome(source: .iphone, status: status, isTruncated: truncated)
        )
    }

    private func readDeliveredArchive(
        below rootURL: URL,
        mappedDirectory: String,
        maximumBytes: Int
    ) throws -> Data? {
        do {
            return try RemoteNotificationFileReader.readDeliveredArchiveIfPresent(
                below: rootURL,
                mappedDirectory: mappedDirectory,
                maximumBytes: maximumBytes
            )
        } catch RemoteNotificationStoreError.changedDuringRead {
            return try RemoteNotificationFileReader.readDeliveredArchiveIfPresent(
                below: rootURL,
                mappedDirectory: mappedDirectory,
                maximumBytes: maximumBytes
            )
        }
    }
}

private indirect enum BinaryPlistValue {
    case null
    case bool(Bool)
    case integer(UInt64)
    case real(Double)
    case date(Date)
    case data(Data)
    case string(String)
    /// A UTF-16 string object whose code units are not valid UTF-16. Only
    /// `KeyedArchiveGraph.freeText` accepts it; every other reader rejects it.
    case damagedUTF16(Data)
    case uid(Int)
    case array([BinaryPlistValue])
    case dictionary([(BinaryPlistValue, BinaryPlistValue)])
}

private struct BinaryPropertyListParser {
    let data: Data
    let maximumObjects: Int
    let maximumDepth: Int
    private var cache: [Int: BinaryPlistValue] = [:]
    private var visiting: Set<Int> = []

    init(data: Data, maximumObjects: Int, maximumDepth: Int) {
        self.data = data
        self.maximumObjects = maximumObjects
        self.maximumDepth = maximumDepth
    }

    mutating func parse() throws -> BinaryPlistValue {
        guard data.count >= 40, data.prefix(8) == Data("bplist00".utf8) else { throw malformed }
        let trailer = data.count - 32
        let offsetSize = Int(data[trailer + 6])
        let referenceSize = Int(data[trailer + 7])
        let objectCount = try integer(at: trailer + 8, byteCount: 8)
        let topObject = try integer(at: trailer + 16, byteCount: 8)
        let offsetTable = try integer(at: trailer + 24, byteCount: 8)
        guard offsetSize > 0, referenceSize > 0,
            objectCount <= UInt64(maximumObjects), topObject < objectCount,
            objectCount <= UInt64(Int.max), offsetTable <= UInt64(Int.max)
        else { throw RemoteNotificationStoreError.exceededLimit }

        let count = Int(objectCount)
        let table = Int(offsetTable)
        guard table <= trailer, count <= (trailer - table) / offsetSize else { throw malformed }
        let offsets = try (0 ..< count).map { index -> Int in
            let value = try integer(at: table + index * offsetSize, byteCount: offsetSize)
            guard value < UInt64(table), value <= UInt64(Int.max) else { throw malformed }
            return Int(value)
        }
        return try object(at: Int(topObject), offsets: offsets, referenceSize: referenceSize, depth: 0)
    }

    private mutating func object(
        at index: Int,
        offsets: [Int],
        referenceSize: Int,
        depth: Int
    ) throws -> BinaryPlistValue {
        if let cached = cache[index] { return cached }
        guard depth <= maximumDepth, offsets.indices.contains(index) else { throw malformed }
        guard visiting.insert(index).inserted else { throw malformed }
        defer { visiting.remove(index) }
        let value = try parseObject(at: index, offsets: offsets, referenceSize: referenceSize, depth: depth)
        cache[index] = value
        return value
    }

    private mutating func parseObject(
        at index: Int,
        offsets: [Int],
        referenceSize: Int,
        depth: Int
    ) throws -> BinaryPlistValue {
        var cursor = offsets[index]
        guard data.indices.contains(cursor) else { throw malformed }
        let marker = data[cursor]
        cursor += 1
        let type = marker >> 4
        let info = Int(marker & 0x0F)

        switch type {
        case 0x0:
            if info == 0 { return .null }
            if info == 8 { return .bool(false) }
            if info == 9 { return .bool(true) }
        case 0x1:
            let byteCount = 1 << info
            return .integer(try integer(at: cursor, byteCount: byteCount))
        case 0x2:
            let byteCount = 1 << info
            let bits = try integer(at: cursor, byteCount: byteCount)
            if byteCount == 4 { return .real(Double(Float(bitPattern: UInt32(bits)))) }
            if byteCount == 8 { return .real(Double(bitPattern: bits)) }
        case 0x3:
            guard info == 3 else { throw malformed }
            return .date(
                Date(timeIntervalSinceReferenceDate: Double(bitPattern: try integer(at: cursor, byteCount: 8)))
            )
        case 0x4:
            let (count, start) = try length(info: info, cursor: cursor)
            return .data(try bytes(at: start, count: count))
        case 0x5:
            let (count, start) = try length(info: info, cursor: cursor)
            guard let string = String(data: try bytes(at: start, count: count), encoding: .ascii) else {
                throw malformed
            }
            return .string(string)
        case 0x6:
            let (count, start) = try length(info: info, cursor: cursor)
            guard count <= Int.max / 2 else { throw malformed }
            let codeUnits = try bytes(at: start, count: count * 2)
            guard let string = String(data: codeUnits, encoding: .utf16BigEndian) else {
                return .damagedUTF16(codeUnits)
            }
            return .string(string)
        case 0x8:
            let value = try integer(at: cursor, byteCount: info + 1)
            guard value <= UInt64(Int.max) else { throw malformed }
            return .uid(Int(value))
        case 0xA:
            let (count, start) = try length(info: info, cursor: cursor)
            let references = try referenceIndexes(
                at: start,
                count: count,
                byteCount: referenceSize,
                maximum: offsets.count
            )
            return .array(
                try references.map {
                    try object(at: $0, offsets: offsets, referenceSize: referenceSize, depth: depth + 1)
                }
            )
        case 0xD:
            let (count, start) = try length(info: info, cursor: cursor)
            guard count <= Int.max / referenceSize else { throw malformed }
            let keys = try referenceIndexes(at: start, count: count, byteCount: referenceSize, maximum: offsets.count)
            let values = try referenceIndexes(
                at: start + count * referenceSize,
                count: count,
                byteCount: referenceSize,
                maximum: offsets.count
            )
            return .dictionary(
                try zip(keys, values).map {
                    (
                        try object(at: $0.0, offsets: offsets, referenceSize: referenceSize, depth: depth + 1),
                        try object(at: $0.1, offsets: offsets, referenceSize: referenceSize, depth: depth + 1)
                    )
                }
            )
        default:
            break
        }
        throw malformed
    }

    private func length(info: Int, cursor: Int) throws -> (Int, Int) {
        guard info == 0xF else { return (info, cursor) }
        guard data.indices.contains(cursor), data[cursor] >> 4 == 0x1 else { throw malformed }
        let byteCount = 1 << Int(data[cursor] & 0x0F)
        let value = try integer(at: cursor + 1, byteCount: byteCount)
        guard value <= UInt64(Int.max) else { throw RemoteNotificationStoreError.exceededLimit }
        return (Int(value), cursor + 1 + byteCount)
    }

    private func referenceIndexes(at start: Int, count: Int, byteCount: Int, maximum: Int) throws -> [Int] {
        guard count >= 0, byteCount > 0, count <= (data.count - min(start, data.count)) / byteCount else {
            throw malformed
        }
        return try (0 ..< count).map { item in
            let value = try integer(at: start + item * byteCount, byteCount: byteCount)
            guard value < UInt64(maximum) else { throw malformed }
            return Int(value)
        }
    }

    private func integer(at start: Int, byteCount: Int) throws -> UInt64 {
        guard byteCount > 0, byteCount <= 8, start >= 0, start <= data.count - byteCount else { throw malformed }
        return data[start ..< (start + byteCount)].reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private func bytes(at start: Int, count: Int) throws -> Data {
        guard count >= 0, start >= 0, start <= data.count - count else { throw malformed }
        return data.subdata(in: start ..< (start + count))
    }

    private var malformed: RemoteNotificationStoreError { .malformed }
}

// Walks the archive by bounded UID traversal over parsed plist values and
// never uses `NSKeyedUnarchiver`, which would instantiate classes the iPhone
// store names.
private struct KeyedArchiveGraph {
    let objects: [BinaryPlistValue]
    let rootReference: BinaryPlistValue

    init(root: BinaryPlistValue) throws {
        guard let archive = root.stringDictionary,
            case .string("NSKeyedArchiver")? = archive["$archiver"],
            case .array(let objects)? = archive["$objects"],
            let top = archive["$top"]?.stringDictionary,
            let rootReference = top["root"]
        else { throw RemoteNotificationStoreError.malformed }
        self.objects = objects
        self.rootReference = rootReference
    }

    func rootArray(maximumDepth: Int) throws -> [BinaryPlistValue] {
        try array(rootReference, maximumDepth: maximumDepth)
    }

    func rootDictionary(maximumDepth: Int) throws -> [String: BinaryPlistValue] {
        try dictionary(rootReference, maximumDepth: maximumDepth)
    }

    func array(_ value: BinaryPlistValue, maximumDepth: Int) throws -> [BinaryPlistValue] {
        let object = try dereference(value, depth: 0, maximumDepth: maximumDepth)
        if case .string("$null") = object { return [] }
        if case .array(let values) = object { return values }
        guard let fields = object.stringDictionary,
            try className(fields, maximumDepth: maximumDepth) == "NSArray"
                || className(fields, maximumDepth: maximumDepth) == "NSMutableArray",
            case .array(let values)? = fields["NS.objects"]
        else { throw RemoteNotificationStoreError.malformed }
        return values
    }

    func dictionary(_ value: BinaryPlistValue, maximumDepth: Int) throws -> [String: BinaryPlistValue] {
        let object = try dereference(value, depth: 0, maximumDepth: maximumDepth)
        guard let fields = object.stringDictionary else { throw RemoteNotificationStoreError.malformed }
        if fields["NS.keys"] == nil { return fields }
        let name = try className(fields, maximumDepth: maximumDepth)
        guard name == "NSDictionary" || name == "NSMutableDictionary",
            case .array(let keys)? = fields["NS.keys"],
            case .array(let values)? = fields["NS.objects"], keys.count == values.count
        else { throw RemoteNotificationStoreError.malformed }
        var result: [String: BinaryPlistValue] = [:]
        for (key, value) in zip(keys, values) {
            guard let text = try string(key, maximumDepth: maximumDepth) else {
                throw RemoteNotificationStoreError.malformed
            }
            result[text] = value
        }
        return result
    }

    func string(_ value: BinaryPlistValue?, maximumDepth: Int) throws -> String? {
        guard let value else { return nil }
        let object = try dereference(value, depth: 0, maximumDepth: maximumDepth)
        if case .string("$null") = object { return nil }
        guard case .string(let text) = object else { throw RemoteNotificationStoreError.malformed }
        return text
    }

    /// Reads a notification's title, subtitle, or body. Unlike `string`, it
    /// keeps invalid UTF-16 as evidence so one damaged preview cannot hide the
    /// record or the rest of its app's archive.
    func freeText(
        _ value: BinaryPlistValue?,
        field: DamagedNotificationText.Field,
        maximumDepth: Int
    ) throws -> ArchivedFreeText? {
        guard let value else { return nil }
        switch try dereference(value, depth: 0, maximumDepth: maximumDepth) {
        case .string("$null"): return nil
        case .string(let text): return .text(text)
        case .damagedUTF16(let codeUnits):
            return .damaged(DamagedNotificationText(field: field, utf16BigEndian: codeUnits))
        default: throw RemoteNotificationStoreError.malformed
        }
    }

    func date(_ value: BinaryPlistValue?, maximumDepth: Int) throws -> Date? {
        guard let value else { return nil }
        let object = try dereference(value, depth: 0, maximumDepth: maximumDepth)
        if case .string("$null") = object { return nil }
        if case .date(let date) = object { return date }
        guard let fields = object.stringDictionary, try className(fields, maximumDepth: maximumDepth) == "NSDate",
            let timeValue = fields["NS.time"]
        else { throw RemoteNotificationStoreError.malformed }
        let resolved = try dereference(timeValue, depth: 1, maximumDepth: maximumDepth)
        switch resolved {
        case .real(let seconds): return Date(timeIntervalSinceReferenceDate: seconds)
        case .integer(let seconds): return Date(timeIntervalSinceReferenceDate: TimeInterval(seconds))
        default: throw RemoteNotificationStoreError.malformed
        }
    }

    private func className(_ fields: [String: BinaryPlistValue], maximumDepth: Int) throws -> String {
        guard let classReference = fields["$class"],
            let classFields = try dereference(classReference, depth: 0, maximumDepth: maximumDepth).stringDictionary,
            case .string(let name)? = classFields["$classname"]
        else { throw RemoteNotificationStoreError.malformed }
        return name
    }

    private func dereference(
        _ value: BinaryPlistValue,
        depth: Int,
        maximumDepth: Int
    ) throws -> BinaryPlistValue {
        guard depth <= maximumDepth else { throw RemoteNotificationStoreError.exceededLimit }
        guard case .uid(let index) = value else { return value }
        guard objects.indices.contains(index) else { throw RemoteNotificationStoreError.malformed }
        let object = objects[index]
        if case .uid = object { return try dereference(object, depth: depth + 1, maximumDepth: maximumDepth) }
        return object
    }
}

private enum ArchivedFreeText {
    case text(String)
    case damaged(DamagedNotificationText)

    var text: String? {
        guard case .text(let text) = self else { return nil }
        return text
    }

    var damage: DamagedNotificationText? {
        guard case .damaged(let damage) = self else { return nil }
        return damage
    }
}

extension BinaryPlistValue {
    fileprivate var stringDictionary: [String: BinaryPlistValue]? {
        guard case .dictionary(let pairs) = self else { return nil }
        var result: [String: BinaryPlistValue] = [:]
        for (key, value) in pairs {
            guard case .string(let text) = key else { return nil }
            result[text] = value
        }
        return result
    }
}
