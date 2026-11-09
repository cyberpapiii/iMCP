import CoreLocation
import Foundation
import JSONSchema
import MCP

/// One tool argument: the JSON Schema a client reads and the parser the tool
/// runs, made from one value, so the documented default, range, and choices
/// are the ones enforced.
///
/// The parsing policy every kind follows: a missing key or JSON null takes
/// the default. A size or count outside its range is clamped into it. A value
/// of the wrong type throws a `ToolInputError` that names the key.
/// Identifiers, coordinates, dates, and choices never fall back, so a typo
/// cannot quietly answer a different question.
struct ToolArgument<Output>: ToolArgumentDeclaration {
    let properties: [(key: String, schema: JSONSchema)]
    let requiredKeys: [String]
    private let read: @Sendable ([String: Value]) throws -> Output

    init(
        properties: [(key: String, schema: JSONSchema)],
        required: [String] = [],
        read: @escaping @Sendable ([String: Value]) throws -> Output
    ) {
        self.properties = properties
        self.requiredKeys = required
        self.read = read
    }

    /// One key. `read` gets the value under it, or nil when it is missing or
    /// JSON null.
    init(
        _ key: String,
        _ schema: JSONSchema,
        isRequired: Bool = false,
        read: @escaping @Sendable (Value?) throws -> Output
    ) {
        self.init(properties: [(key, schema)], required: isRequired ? [key] : []) { arguments in
            try read(presentArgument(arguments, key))
        }
    }

    func callAsFunction(_ arguments: [String: Value]) throws -> Output {
        try read(arguments)
    }

    func map<T>(_ transform: @escaping @Sendable (Output) throws -> T) -> ToolArgument<T> {
        let read = self.read
        return ToolArgument<T>(properties: properties, required: requiredKeys) { try transform(read($0)) }
    }
}

/// What `Tool` needs from an argument to write its input schema.
protocol ToolArgumentDeclaration: Sendable {
    var properties: [(key: String, schema: JSONSchema)] { get }
    var requiredKeys: [String] { get }
}

/// The bounds every list tool shares.
enum ListLimit {
    static let `default` = 30
    static let max = 500
}

/// Sentences more than one tool's schema uses.
enum ArgumentDescription {
    static let rangeStart = "Start of the date range (inclusive), in ISO 8601 format"
    static let rangeEnd = "End of the date range (exclusive), in ISO 8601 format"
    static let maxDimension = "Maximum width or height in pixels; larger images are scaled down"
    /// What the lenient date parser does with a string that has no offset.
    static let localTimeAssumed = "If timezone is omitted, local time is assumed."
}

extension ToolInputError {
    static func wrongType(_ key: String, _ expected: String) -> ToolInputError {
        ToolInputError("\(key) must be \(expected)")
    }

    static func invalidChoice(_ key: String, _ names: [String]) -> ToolInputError {
        ToolInputError("Invalid \(key). Expected one of: \(names.joined(separator: ", ")).")
    }

    /// A date range whose start, given or defaulted, is not before its end.
    static func startNotBeforeEnd(_ startKey: String, _ endKey: String) -> ToolInputError {
        ToolInputError("\(startKey) must be earlier than \(endKey)")
    }
}

/// The value under `key`, with an explicit JSON null read as no value at all:
/// clients routinely send null for an optional they are leaving out.
func presentArgument(_ arguments: [String: Value], _ key: String) -> Value? {
    guard let value = arguments[key], value != .null else { return nil }
    return value
}

extension Value {
    /// A JSON number as a `Double`, whether the client sent `40` or `40.0`.
    ///
    /// The SDK decodes `40` as `.int` and `doubleValue` answers nil for it, so
    /// a tool that reads `doubleValue` silently falls back to its default
    /// whenever a caller passes a whole number. Every numeric tool argument
    /// reads this instead.
    public var numberValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    /// A whole JSON number as an `Int`, whether the client sent `40` or `40.0`.
    ///
    /// Fractional, non-finite, and out-of-range numbers answer nil. `Int(_:)`
    /// on such a `Double` traps, so no tool argument goes through it.
    public var wholeNumberValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(exactly: value)
        default: return nil
        }
    }
}

// MARK: - Value readers

/// Readers for one present value, shared by the kinds below and by nested
/// fields such as an alarm's.
enum ArgumentValue {
    static func string(_ value: Value, _ key: String) throws -> String {
        guard case .string(let string) = value else { throw ToolInputError.wrongType(key, "a string") }
        return string
    }

    static func nonBlankString(_ value: Value, _ key: String) throws -> String {
        let string = try string(value, key)
        guard string.contains(where: { !$0.isWhitespace }) else {
            throw ToolInputError("\(key) must not be empty")
        }
        return string
    }

    /// The string without its surrounding whitespace; nothing left throws.
    /// `message` replaces both the wrong-type and the empty error.
    static func trimmedNonBlankString(_ value: Value, _ key: String, message: String? = nil) throws -> String {
        guard case .string(let raw) = value else {
            throw message.map(ToolInputError.init) ?? .wrongType(key, "a string")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ToolInputError(message ?? "\(key) must not be empty") }
        return trimmed
    }

    static func object(_ value: Value, _ key: String) throws -> [String: Value] {
        guard case .object(let object) = value else { throw ToolInputError.wrongType(key, "an object") }
        return object
    }

    static func bool(_ value: Value, _ key: String) throws -> Bool {
        guard case .bool(let bool) = value else { throw ToolInputError.wrongType(key, "true or false") }
        return bool
    }

    static func wholeNumber(_ value: Value, _ key: String) throws -> Int {
        guard let number = value.wholeNumberValue else { throw ToolInputError.wrongType(key, "a whole number") }
        return number
    }

    static func number(_ value: Value, _ key: String) throws -> Double {
        guard let number = value.numberValue, !number.isNaN else { throw ToolInputError.wrongType(key, "a number") }
        return number
    }

    /// Case is forgiven ("High"); a name that is not in the table never is.
    static func choice<Choice>(_ value: Value, _ key: String, among table: NamedCases<Choice>) throws -> Choice {
        let wanted = value.stringValue?.lowercased()
        guard let entry = table.entries.first(where: { $0.name.lowercased() == wanted }) else {
            throw ToolInputError.invalidChoice(key, table.names)
        }
        return entry.value
    }

    /// Each entry read by `element`; an entry that throws fails the whole
    /// argument, and the error names its index.
    static func array<Element>(_ value: Value, _ key: String, _ element: (Value) throws -> Element) throws
        -> [Element]
    {
        guard case .array(let entries) = value else { throw ToolInputError.wrongType(key, "an array") }
        return try entries.enumerated().map { index, entry in
            do {
                return try element(entry)
            } catch let error as ToolInputError {
                throw ToolInputError("\(key)[\(index)]: \(error.message)")
            }
        }
    }

    /// `read` applied to the value under `key` of a nested object, or nil
    /// when it is missing or JSON null.
    static func optional<T>(_ object: [String: Value], _ key: String, _ read: (Value, String) throws -> T) rethrows
        -> T?
    {
        try presentArgument(object, key).map { try read($0, key) }
    }

    /// An ISO 8601 date or date-time, read by the lenient parser.
    static func date(_ value: Value, _ key: String) throws -> ParsedDate {
        guard case .string(let string) = value,
            !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let parsed = ISO8601DateFormatter.parsedLenientISO8601Date(fromISO8601String: string)
        else {
            throw ToolInputError("\(key) must be an ISO 8601 date or date-time")
        }
        return ParsedDate(date: parsed.date, isDateOnly: parsed.isDateOnly)
    }
}

/// A parsed date argument, and whether it named a day with no time.
struct ParsedDate: Equatable {
    let date: Date
    let isDateOnly: Bool

    /// A date-only start snaps to local midnight.
    func asStart(calendar: Calendar = .current) -> Date {
        calendar.normalizedStartDate(from: date, isDateOnly: isDateOnly)
    }

    /// A date-only end moves to the following midnight, so the day is included.
    func asEnd(calendar: Calendar = .current) -> Date {
        calendar.normalizedEndDate(from: date, isDateOnly: isDateOnly)
    }
}

/// Optional bounds of a date range. `start` is inclusive and `end` exclusive.
struct DateWindow: Equatable {
    var start: Date?
    var end: Date?
}

// MARK: - Kinds

extension ToolArgument where Output == Int {
    /// A count or size: the schema's default and bounds are the ones enforced.
    /// `documentsRange: false` clamps into `range` without writing it into
    /// the schema.
    static func integer(
        _ key: String,
        description: String? = nil,
        default value: Int,
        in range: ClosedRange<Int>,
        documentsRange: Bool = true
    ) -> Self {
        Self(
            key,
            .integer(
                description: description,
                default: .int(value),
                minimum: documentsRange ? range.lowerBound : nil,
                maximum: documentsRange ? range.upperBound : nil
            )
        ) { present in
            guard let present else { return value }
            return try ArgumentValue.wholeNumber(present, key).bounded(to: range)
        }
    }

    static func limit(
        _ description: String,
        default value: Int = ListLimit.default,
        minimum: Int = 0,
        maximum: Int = ListLimit.max
    ) -> Self {
        integer("limit", description: description, default: value, in: minimum ... maximum)
    }
}

extension ToolArgument where Output == Int? {
    /// A whole number with no default. Bounds are documented, not clamped:
    /// the tool decides what an out-of-range value means.
    static func integer(_ key: String, description: String? = nil, minimum: Int? = nil) -> Self {
        Self(key, .integer(description: description, minimum: minimum)) { present in
            try present.map { try ArgumentValue.wholeNumber($0, key) }
        }
    }
}

extension ToolArgument where Output == Double {
    /// `documentsRange: false` clamps into `range` without writing it into
    /// the schema.
    static func number(
        _ key: String,
        description: String? = nil,
        default value: Double,
        in range: ClosedRange<Double>? = nil,
        documentsRange: Bool = true
    ) -> Self {
        let documented = documentsRange ? range : nil
        return Self(
            key,
            .number(
                description: description,
                default: .double(value),
                minimum: documented?.lowerBound,
                maximum: documented?.upperBound
            )
        ) { present in
            guard let present else { return value }
            let number = try ArgumentValue.number(present, key)
            guard let range else { return number }
            return min(max(number, range.lowerBound), range.upperBound)
        }
    }
}

extension ToolArgument where Output == Double? {
    static func number(_ key: String, description: String? = nil) -> Self {
        Self(key, .number(description: description)) { present in
            try present.map { try ArgumentValue.number($0, key) }
        }
    }
}

extension ToolArgument where Output == Bool {
    static func bool(_ key: String, description: String? = nil, default value: Bool) -> Self {
        Self(key, .boolean(description: description, default: .bool(value))) { present in
            guard let present else { return value }
            return try ArgumentValue.bool(present, key)
        }
    }
}

extension ToolArgument where Output == Bool? {
    /// `documentedDefault` is what the framework does when the key is
    /// absent; the schema names it, and the parser still answers nil.
    static func bool(
        _ key: String,
        description: String? = nil,
        documentedDefault: Bool? = nil
    ) -> Self {
        Self(key, .boolean(description: description, default: documentedDefault.map { .bool($0) })) { present in
            try present.map { try ArgumentValue.bool($0, key) }
        }
    }
}

extension ToolArgument where Output == String? {
    static func string(_ key: String, description: String? = nil, format: StringFormat? = nil) -> Self {
        Self(key, .string(description: description, format: format)) { present in
            try present.map { try ArgumentValue.string($0, key) }
        }
    }

    /// A string that has to say something: an empty or all-whitespace one
    /// throws.
    static func nonBlankString(_ key: String, description: String? = nil, format: StringFormat? = nil) -> Self {
        Self(key, .string(description: description, format: format)) { present in
            try present.map { try ArgumentValue.nonBlankString($0, key) }
        }
    }

    /// A search term. An empty one, or with `trimmed` an all-whitespace one,
    /// means no search.
    static func searchTerm(_ description: String, key: String = "query", trimmed: Bool = false) -> Self {
        text(key, description: description, trimmed: trimmed)
    }

    /// An optional filter where an empty string means no filter.
    static func text(_ key: String, description: String? = nil, trimmed: Bool = false) -> Self {
        Self(key, .string(description: description)) { present in
            guard let present else { return nil }
            let raw = try ArgumentValue.string(present, key)
            let term = trimmed ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : raw
            return term.isEmpty ? nil : term
        }
    }
}

extension ToolArgument where Output == String {
    /// A required string that has to say something, such as an identifier
    /// or a name.
    static func required(_ key: String, description: String? = nil) -> Self {
        Self(key, .string(description: description), isRequired: true) { present in
            guard let present else { throw ToolInputError("\(key) is required") }
            return try ArgumentValue.nonBlankString(present, key)
        }
    }
}

extension ToolArgument where Output: Equatable {
    /// One name from `table`, or `defaultValue` when the key is missing. The
    /// schema lists the names in table order. With `unknownFallsBack`, a
    /// name not in the table also reads as the default.
    static func choice(
        _ key: String,
        description: String? = nil,
        among table: NamedCases<Output>,
        default defaultValue: Output,
        unknownFallsBack: Bool = false
    ) -> Self {
        Self(
            key,
            .string(
                description: description,
                default: table.name(of: defaultValue).map { .string($0) },
                enum: table.names.map { .string($0) }
            )
        ) { present in
            guard let present else { return defaultValue }
            if unknownFallsBack {
                return (try? ArgumentValue.choice(present, key, among: table)) ?? defaultValue
            }
            return try ArgumentValue.choice(present, key, among: table)
        }
    }
}

extension ToolArgument where Output: Equatable {
    static func requiredChoice(_ key: String, description: String? = nil, among table: NamedCases<Output>) -> Self {
        Self(key, .string(description: description, enum: table.names.map { .string($0) }), isRequired: true) {
            present in
            guard let present else { throw ToolInputError("\(key) is required") }
            return try ArgumentValue.choice(present, key, among: table)
        }
    }
}

extension ToolArgument where Output: RawRepresentable & CaseIterable & Equatable, Output.RawValue == String {
    /// One case of `Output`, by raw value, in `allCases` order.
    static func choice(_ key: String, description: String? = nil, default defaultValue: Output) -> Self {
        choice(key, description: description, among: NamedCases(), default: defaultValue)
    }
}

extension ToolArgument {
    /// One name from `table`, or nil when the key is missing.
    /// `documentedDefault` is what the framework does when the key is
    /// absent; the schema names it, and the parser still answers nil.
    static func choice<Choice: Equatable>(
        _ key: String,
        description: String? = nil,
        among table: NamedCases<Choice>,
        documentedDefault: Choice? = nil
    ) -> Self where Output == Choice? {
        Self(
            key,
            .string(
                description: description,
                default: documentedDefault.flatMap { table.name(of: $0) }.map { .string($0) },
                enum: table.names.map { .string($0) }
            )
        ) { present in
            try present.map { try ArgumentValue.choice($0, key, among: table) }
        }
    }

    /// A date or date-time. `alias` is a second key that is read when `key`
    /// is absent and that the schema does not document.
    static func date(
        _ key: String,
        description: String? = nil,
        alias: String? = nil,
        isRequired: Bool = false
    ) -> Self where Output == ParsedDate? {
        Self(
            properties: [(key, .string(description: description, format: .dateTime))],
            required: isRequired ? [key] : []
        ) { arguments in
            let keys = [key] + (alias.map { [$0] } ?? [])
            guard let present = keys.lazy.compactMap({ presentArgument(arguments, $0) }).first else { return nil }
            return try ArgumentValue.date(present, key)
        }
    }

    /// Optional bounds: a date-only start is that day's midnight, a
    /// date-only end the following midnight. A start that is not before the
    /// end throws.
    static func dateWindow(
        start startKey: String = "startDate",
        _ startDescription: String? = ArgumentDescription.rangeStart,
        end endKey: String = "endDate",
        _ endDescription: String? = ArgumentDescription.rangeEnd,
        aliases: (start: String, end: String)? = ("start", "end")
    ) -> Self where Output == DateWindow {
        let start = ToolArgument<ParsedDate?>.date(startKey, description: startDescription, alias: aliases?.start)
        let end = ToolArgument<ParsedDate?>.date(endKey, description: endDescription, alias: aliases?.end)
        return Self(properties: start.properties + end.properties) { arguments in
            let window = DateWindow(start: try start(arguments)?.asStart(), end: try end(arguments)?.asEnd())
            if let from = window.start, let to = window.end, from >= to {
                throw ToolInputError.startNotBeforeEnd(startKey, endKey)
            }
            return window
        }
    }

    static func array<Element>(
        _ key: String,
        description: String? = nil,
        items: JSONSchema,
        _ element: @escaping @Sendable (Value) throws -> Element
    ) -> Self where Output == [Element]? {
        Self(key, .array(description: description, items: items)) { present in
            try present.map { try ArgumentValue.array($0, key, element) }
        }
    }

    static func strings(_ key: String, description: String? = nil) -> Self where Output == [String]? {
        array(key, description: description, items: .string()) { try ArgumentValue.string($0, "entry") }
    }

    /// A required latitude/longitude pair that names a real point on Earth.
    static func coordinate(
        latitude latitudeKey: String = "latitude",
        longitude longitudeKey: String = "longitude",
        latitudeDescription: String? = nil,
        longitudeDescription: String? = nil
    ) -> Self where Output == CLLocationCoordinate2D {
        Self(
            properties: [
                (latitudeKey, .number(description: latitudeDescription)),
                (longitudeKey, .number(description: longitudeDescription)),
            ],
            required: [latitudeKey, longitudeKey]
        ) { arguments in
            guard let latitude = arguments[latitudeKey]?.numberValue,
                let longitude = arguments[longitudeKey]?.numberValue
            else {
                throw ToolInputError("\(latitudeKey) and \(longitudeKey) are required numbers")
            }
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            guard latitude.isFinite, longitude.isFinite, CLLocationCoordinate2DIsValid(coordinate) else {
                throw ToolInputError(
                    "\(latitudeKey) must be between -90 and 90 and \(longitudeKey) between -180 and 180"
                )
            }
            return coordinate
        }
    }
}
