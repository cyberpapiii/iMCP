import Foundation

/// A query that names nobody either provider can see.
enum LocationPersonError: Swift.Error, ClientFacingError, Equatable {
    case unknownPerson(String)

    var errorDescription: String? {
        switch self {
        case .unknownPerson(let name):
            return
                "No one named \"\(name)\" is sharing a location. Call location_people or location_friends for the names that exist."
        }
    }
}

/// Where a person is now, and which provider said so.
struct ResolvedPosition: Equatable, Sendable {
    enum Provider: Equatable, Sendable {
        /// Find My on the web: the user and Family Sharing members.
        case web
        /// Find My People, from this Mac's local cache.
        case people
    }

    let latitude: Double
    let longitude: Double
    let provider: Provider
}

extension FindMySnapshot {
    var owners: [String: FindMyPerson] {
        var owners: [String: FindMyPerson] = [:]
        for person in people {
            for device in person.devices {
                owners[device.id] = person
            }
        }
        return owners
    }
}

/// Finds one person by a caller's query across both providers, and refuses
/// to guess when more than one could be meant.
struct LocationPersonResolver: Sendable {
    let readiness: FindMyPeopleReadiness
    /// Find My's cached view; never asks a device to locate itself.
    let snapshot: @Sendable () async throws -> FindMySnapshot

    /// The one device of the user's own that `query` names: its id as
    /// `location_devices` reports it, or its name when that is unambiguous.
    static func ownDevice(matching query: String, in devices: [FindMyDevice]) throws -> FindMyDevice {
        let mine = devices.filter { $0.ownerID == nil }
        if let exact = mine.first(where: { $0.id == query }) { return exact }
        let named = mine.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
        guard named.count < 2 else {
            throw ToolInputError(
                "More than one of your devices is named \"\(query)\". "
                    + "Pass one of these ids as device: \(named.map(\.id).sorted().joined(separator: ", "))."
            )
        }
        guard let device = named.first else { throw FindMyError.unknownDevice(query) }
        return device
    }

    /// A friend identifier goes straight to Find My People, and a web
    /// person's identifier straight to Find My on the web. Anything else is a
    /// name, looked up in both providers; the order below decides.
    func position(for query: String) async throws -> ResolvedPosition {
        switch LocationSubjectKey.parse(query) {
        case .friend(let identifier):
            return Self.position(of: try await readiness.friend(matching: identifier))
        case .webPerson(let identifier):
            guard let match = WebMatch.located(in: try await snapshot()).first(where: { $0.identifier == identifier })
            else { throw LocationPersonError.unknownPerson(query) }
            return match.position
        case .name(let name):
            return try await position(named: name)
        }
    }

    private func position(named query: String) async throws -> ResolvedPosition {
        // An ambiguous People name is final: a web match cannot settle it.
        var local: Result<FindMyFriendReport, Error>?
        if await readiness.isPeopleEnabled() {
            do {
                local = .success(try await readiness.friend(matching: query))
            } catch FindMyPeopleToolError.ambiguousName(let name, let identifiers) {
                throw FindMyPeopleToolError.ambiguousName(name, identifiers: identifiers)
            } catch {
                local = .failure(error)
            }
        }
        let web: Result<WebMatches, Error>
        do {
            web = .success(WebMatches(query: query, in: try await snapshot()))
        } catch {
            web = .failure(error)
        }

        switch (local, web) {
        case (.success(let friend)?, .success(let matches)) where !matches.exact.isEmpty:
            throw FindMyPeopleToolError.ambiguousName(
                query,
                identifiers: ([friend.identifier] + matches.exact.identifiers).sorted()
            )
        case (.success(let friend)?, _):
            return Self.position(of: friend)
        case (_, .success(let matches)) where matches.exact.count > 1:
            throw FindMyPeopleToolError.ambiguousName(query, identifiers: matches.exact.identifiers)
        case (_, .success(let matches)) where matches.exact.count == 1:
            return matches.exact[0].position
        case (_, .success(let matches)) where matches.partial.count > 1:
            throw FindMyPeopleToolError.ambiguousName(query, identifiers: matches.partial.identifiers)
        case (_, .success(let matches)) where matches.partial.count == 1:
            return matches.partial[0].position
        case (.failure(let error)?, _), (nil, .failure(let error)):
            throw error
        case (nil, .success):
            throw LocationPersonError.unknownPerson(query)
        }
    }

    private static func position(of friend: FindMyFriendReport) -> ResolvedPosition {
        ResolvedPosition(latitude: friend.latitude, longitude: friend.longitude, provider: .people)
    }

    /// The web people with a position whose name is `query`, then those whose
    /// name contains it.
    private struct WebMatches {
        let exact: [WebMatch]
        let partial: [WebMatch]

        init(query: String, in snapshot: FindMySnapshot) {
            let located = WebMatch.located(in: snapshot)
            exact = located.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
            partial = located.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
    }
}

/// A web person with a position. Web people who share a name share an
/// identifier, so they are one person here as in history and visits
/// (`LocationSubjectKey.person`), wherever the freshest of their devices is.
private struct WebMatch {
    let name: String
    let identifier: String
    let position: ResolvedPosition

    static func located(in snapshot: FindMySnapshot) -> [WebMatch] {
        Dictionary(grouping: snapshot.people) { LocationSubjectKey.webPerson(named: $0.name) }
            .compactMap { identifier, people in
                let name = people[0].name
                let merged = FindMyPerson(id: nil, name: name, isMe: false, devices: people.flatMap(\.devices))
                guard let best = merged.bestFix else { return nil }
                return WebMatch(
                    name: name,
                    identifier: identifier,
                    position: ResolvedPosition(
                        latitude: best.fix.latitude,
                        longitude: best.fix.longitude,
                        provider: .web
                    )
                )
            }
    }
}

extension [WebMatch] {
    fileprivate var identifiers: [String] { map(\.identifier).sorted() }
}
