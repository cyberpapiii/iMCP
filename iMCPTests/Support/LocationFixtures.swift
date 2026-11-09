import Foundation

@testable import iMCP

/// A session that has never been signed in and never reaches Apple.
@MainActor let signedOutTestSession = ICloudSession(transport: ScriptedTransport(), storage: storageInMemory().0)

/// Venue lookups that find nothing, without asking Maps.
let noVenues = VenueLookup { _, _, _ in [] }

/// A Find My People gate that is switched off and holds no secrets.
func peopleSwitchedOff() -> FindMyPeopleReadiness {
    FindMyPeopleReadiness(
        storage: peopleKeyStorage(),
        peopleEnabled: false,
        loadPeople: { _ in [] }
    )
}

extension LocationService {
    /// A service whose store, session, and lookups are the test's own, so it
    /// never reads the app's history, session, or Maps.
    static func testing(
        peopleReadiness: FindMyPeopleReadiness,
        historyStore: LocationHistoryStore,
        session: @escaping SessionProvider = { signedOutTestSession },
        venueLookup: VenueLookup = noVenues,
        addresses: @escaping ReverseGeocoder.Loader = { _, _ in nil }
    ) -> LocationService {
        LocationService(
            peopleReadiness: peopleReadiness,
            historyStore: historyStore,
            session: session,
            sampler: LocationSampler(store: historyStore, peopleLoader: { [] }),
            venueLookup: venueLookup,
            addresses: addresses
        )
    }
}
