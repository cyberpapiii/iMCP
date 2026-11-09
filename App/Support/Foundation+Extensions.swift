import Foundation

extension Date {
    /// ISO 8601 with the Mac's own offset, like `2026-09-28T11:49:33-04:00`.
    /// The `.iso8601` format style writes UTC (`2026-09-28T15:49:33Z`), which
    /// models and people read as local wall time. Ontology-encoded results
    /// already carry the local offset, so every tool now agrees.
    var localISO8601: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: self)
    }
}

extension ISO8601DateFormatter {
    /// Tries the common ISO 8601 variants in turn, then falls back to
    /// local-time parsing for strings that carry no timezone.
    static func lenientDate(fromISO8601String dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()

        let optionsToTry: [ISO8601DateFormatter.Options] = [
            // `yyyy-MM-dd'T'HH:mm:ss.SSSZ`, `yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ`
            [.withInternetDateTime, .withFractionalSeconds],

            // `yyyy-MM-dd'T'HH:mm:ssZ`, `yyyy-MM-dd'T'HH:mm:ssZZZZZ`
            [.withInternetDateTime],

            // `yyyy-MM-dd'T'HH:mm:ss.SSS` (no timezone)
            [.withFullDate, .withFullTime, .withFractionalSeconds],

            // `yyyy-MM-dd'T'HH:mm:ss` (no timezone)
            [.withFullDate, .withFullTime],

            // `yyyy-MM-dd HH:mm:ss.SSSZZZZZ`
            [.withFullDate, .withFullTime, .withSpaceBetweenDateAndTime, .withFractionalSeconds],

            // `yyyy-MM-dd HH:mm:ssZZZZZ`
            [.withFullDate, .withFullTime, .withSpaceBetweenDateAndTime],
        ]

        for options in optionsToTry {
            formatter.formatOptions = options
            if let date = formatter.date(from: dateString) {
                return date
            }
        }

        // Give up when the string carries a timezone none of the formats above
        // accepted. Retrying it as local time would silently shift the instant.
        // An offset only counts after a time: the `-05` that ends `2026-10-05`
        // is the day, and reading it as an offset rejected every date-only input.
        let hasTimeZoneInfo =
            dateString.range(
                of: #":\d{2}(\.\d+)?\s?([Zz]|[+-]\d{2}(:?\d{2})?)$"#,
                options: .regularExpression
            ) != nil
        guard !hasTimeZoneInfo else {
            return nil
        }

        let fallbackFormats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd",
        ]

        let fallbackFormatter = DateFormatter()
        fallbackFormatter.locale = Locale(identifier: "en_US_POSIX")
        fallbackFormatter.timeZone = TimeZone.current

        for format in fallbackFormats {
            fallbackFormatter.dateFormat = format
            if let date = fallbackFormatter.date(from: dateString) {
                return date
            }
        }

        return nil
    }

    /// Parses like `lenientDate(fromISO8601String:)` and also reports whether
    /// the input named a day with no time, which callers need to decide
    /// whether an event spans the whole day.
    static func parsedLenientISO8601Date(
        fromISO8601String dateString: String
    ) -> (date: Date, isDateOnly: Bool)? {
        let isDateOnly = isDateOnlyISO8601String(dateString)
        guard let date = lenientDate(fromISO8601String: dateString) else {
            return nil
        }
        return (date, isDateOnly)
    }

    static func isDateOnlyISO8601String(_ dateString: String) -> Bool {
        dateString.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
}

extension Calendar {
    func normalizedStartDate(from date: Date, isDateOnly: Bool) -> Date {
        isDateOnly ? startOfDay(for: date) : date
    }

    /// Pushes a date-only end to midnight of the following day, so the range
    /// covers the whole day the caller asked for. Dates that carried a time
    /// pass through untouched.
    func normalizedEndDate(from date: Date, isDateOnly: Bool) -> Date {
        guard isDateOnly else { return date }
        let startOfDay = startOfDay(for: date)
        return self.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
    }
}

extension Int {
    /// Named to avoid SwiftUI's package `clamped(to:)`.
    func bounded(to range: ClosedRange<Int>) -> Int {
        Swift.max(range.lowerBound, Swift.min(self, range.upperBound))
    }
}

/// Returns `operation`'s result, or throws `timeoutError` if it has not
/// finished within `limit`. On timeout the operation is abandoned rather than
/// awaited: framework calls such as MapKit's do not all honour task
/// cancellation, and waiting for one that never calls back would defeat the
/// deadline. An abandoned camera, recorder, or process keeps running, so
/// `onTimeout` is where the caller stops it; it runs before the error is thrown.
func withDeadline<T: Sendable>(
    _ limit: Duration,
    throwing timeoutError: any Error,
    onTimeout: @escaping @Sendable () async -> Void = {},
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withDeadline(limit, throwing: timeoutError, onTimeout: onTimeout) { report in
        Task {
            do {
                report(.success(try await operation()))
            } catch {
                report(.failure(error))
            }
        }
    }
}

/// The callback form of `withDeadline`, for framework calls that answer
/// through a completion handler or delegate. `start` begins the work and
/// hands `report` to whatever answers; only the first report, or the timeout,
/// counts, so a callback that fires twice is harmless.
func withDeadline<T: Sendable>(
    _ limit: Duration,
    throwing timeoutError: any Error,
    onTimeout: @escaping @Sendable () async -> Void = {},
    reporting start: (_ report: @escaping @Sendable (Result<T, Error>) -> Void) -> Void
) async throws -> T {
    let gate = OnceFlag()
    return try await withCheckedThrowingContinuation { continuation in
        let timer = Task {
            guard (try? await Task.sleep(for: limit)) != nil else { return }
            guard gate.claim() else { return }
            await onTimeout()
            continuation.resume(throwing: timeoutError)
        }
        start { result in
            guard gate.claim() else { return }
            timer.cancel()
            continuation.resume(with: result)
        }
    }
}

extension Data {
    /// Lowercase, two digits per byte.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    /// Nil unless `hexString` is whole bytes of hex digits.
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let end = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index ..< end], radix: 16) else { return nil }
            bytes.append(byte)
            index = end
        }
        self = Data(bytes)
    }
}
