import Foundation

/// `iMCP.app/Contents/MacOS/iMCP --icloud-status`
///
/// Prints what the Keychain holds for the iCloud session and exits, before any
/// window or menu bar item exists. The running app's live state is not
/// reachable from another process, so this reports the snapshot that the next
/// launch would restore from: whether it exists, how old it is, and which
/// cookies in it are still alive. No token values and no account name.
///
/// The data-protection Keychain is invisible to `security
/// find-generic-password`, which is why `Scripts/doctor.sh` asks the app.
enum ICloudStatusCommandLine {
    static let flag = "--icloud-status"

    /// A local estimate of the trust token's lifetime, reported for
    /// diagnosis only. Apple decides validity; local age must never force
    /// another password sign-in.
    static let trustLifetimeDays = 30
    static let trustLifetime = TimeInterval(trustLifetimeDays * 24 * 60 * 60)

    private static func isTrustOlderThanLifetime(_ credentials: ICloudCredentials, asOf now: Date) -> Bool {
        now.timeIntervalSince(credentials.trustedAt) >= trustLifetime
    }

    static func runIfRequested(_ arguments: [String] = CommandLine.arguments) {
        guard arguments.contains(flag) else { return }
        print(report(ICloudCredentialStorage.production.loadBlocking()))
        exit(0)
    }

    static func report(_ result: ICloudCredentialStorage.LoadResult, now: Date = Date()) -> String {
        var lines = ["iCloud session snapshot (Keychain)"]
        switch result {
        case .missing:
            lines.append("  stored: no (never signed in, or signed out)")
        case .unavailable:
            lines.append("  stored: unreadable (the Keychain refused the read)")
        case .found(let credentials):
            lines.append("  stored: yes")
            lines.append("  signed in: \(describe(credentials.trustedAt, relativeTo: now))")
            let updated = credentials.updatedAt ?? credentials.trustedAt
            lines.append("  snapshot written: \(describe(updated, relativeTo: now))")
            lines.append(
                "  trust age: \(isTrustOlderThanLifetime(credentials, asOf: now) ? "older than" : "within") \(trustLifetimeDays) days"
                    + " (Apple decides validity)"
                    + ", session token: \(present(credentials.sessionToken))"
                    + ", trust token: \(present(credentials.trustToken))"
                    + ", saved password: \(present(credentials.password))"
                    + ", client id: \(present(credentials.clientID))"
            )
            lines.append(
                "  cached account: dsid \(present(credentials.dsid))"
                    + ", Find My endpoint \(present(credentials.webservices?["findme"]?.absoluteString))"
            )
            if let attemptedAt = credentials.lastAutomaticReauthenticationAt {
                lines.append("  automatic browser sign-in last tried: \(describe(attemptedAt, relativeTo: now))")
            } else {
                lines.append("  automatic browser sign-in last tried: never")
            }
            lines += otherFields(of: credentials, now: now)
            let cookies = credentials.cookies ?? []
            lines.append("  cookies: \(cookies.count)")
            for cookie in cookies.sorted(by: { $0.name < $1.name }) {
                let expiry: String
                if let expiresAt = cookie.expiresAt {
                    expiry =
                        expiresAt <= now
                        ? "expired \(describe(expiresAt, relativeTo: now))"
                        : "expires \(describe(expiresAt, relativeTo: now))"
                } else {
                    expiry = "session cookie"
                }
                lines.append("    \(cookie.name): \(expiry)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The fields the lines above describe. Every other field of the record
    /// is listed on its own line, so a recovery flag added to
    /// `ICloudCredentials` shows up in the report without being added here.
    private static let describedFields: Set<String> = [
        "accountName", "accountCountry", "sessionToken", "trustToken", "webAuthToken", "webAuthUser",
        "trustedAt", "dsid", "webservices", "cookies", "updatedAt", "password", "clientID",
        "lastAutomaticReauthenticationAt",
    ]

    /// Booleans and dates by value; everything else only as present or
    /// absent, so no token, name, or identifier can reach the report.
    private static func otherFields(of credentials: ICloudCredentials, now: Date) -> [String] {
        Mirror(reflecting: credentials).children.compactMap { child in
            guard let name = child.label, !describedFields.contains(name) else { return nil }
            return "  \(name): \(summary(of: child.value, now: now))"
        }
    }

    private static func summary(of value: Any, now: Date) -> String {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else { return "absent" }
            return summary(of: wrapped, now: now)
        }
        switch value {
        case let flag as Bool: return flag ? "yes" : "no"
        case let date as Date: return describe(date, relativeTo: now)
        default: return "present"
        }
    }

    private static func present(_ value: String?) -> String {
        value.map { $0.isEmpty ? "empty" : "present" } ?? "absent"
    }

    private static func describe(_ date: Date, relativeTo now: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let seconds = Int(abs(now.timeIntervalSince(date)))
        let age: String
        switch seconds {
        case ..<60: age = "\(seconds)s"
        case ..<3600: age = "\(seconds / 60)m"
        case ..<86400: age = "\(seconds / 3600)h \(seconds % 3600 / 60)m"
        default: age = "\(seconds / 86400)d \(seconds % 86400 / 3600)h"
        }
        let direction = date <= now ? "ago" : "from now"
        return "\(formatter.string(from: date)) (\(age) \(direction))"
    }
}
