import Foundation

/// Where a recorded sample came from. Stored in `samples.provider`.
enum LocationSampleProvider {
    static let web = "find-my-web"
    static let people = "find-my-people"
}

/// How a recorded subject is named to a caller, and how a caller's `person`
/// argument names one back. A friend is an opaque `friend_` identifier;
/// anyone seen through the web provider is that provider and their name,
/// because web history is device-scoped on disk but person-scoped to a
/// caller. Every identifier a tool suggests parses back to its subject.
enum LocationSubjectKey {
    static let friendPrefix = "friend_"
    private static let webPrefix = "\(LocationSampleProvider.web):"

    /// What a `person` argument asks for.
    enum Query: Equatable {
        case friend(String)
        /// A web person, as `webPerson(named:)` writes them.
        case webPerson(String)
        case name(String)
    }

    static func parse(_ argument: String) -> Query {
        if isFriend(argument) { return .friend(argument) }
        if argument.hasPrefix(webPrefix), argument.count > webPrefix.count {
            return .webPerson(webPerson(named: String(argument.dropFirst(webPrefix.count))))
        }
        return .name(argument)
    }

    static func isFriend(_ identifier: String) -> Bool {
        identifier.hasPrefix(friendPrefix)
    }

    static func friend(digest: Data) -> String {
        friendPrefix + digest.hexString
    }

    /// One logical person across every device they own, for name ambiguity
    /// and for grouping visits.
    static func person(provider: String, subjectID: String, personName: String) -> String {
        provider == LocationSampleProvider.people ? subjectID : "\(provider):\(personName.lowercased())"
    }

    /// A person seen through Find My on the web.
    static func webPerson(named name: String) -> String {
        person(provider: LocationSampleProvider.web, subjectID: "", personName: name)
    }
}

enum LocationSubjectKind {
    static let device = "device"
    static let person = "person"
}
