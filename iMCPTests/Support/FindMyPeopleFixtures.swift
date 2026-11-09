import Foundation

@testable import iMCP

/// LocalStorage key storage over two in-memory Keychain items.
func peopleKeyStorage(
    database: InMemoryKeychainItem = InMemoryKeychainItem(),
    identity: InMemoryKeychainItem = InMemoryKeychainItem(),
    randomSecret: @escaping @Sendable () -> Data? = { Data(repeating: 8, count: 32) }
) -> LocalStorageKeyStorage {
    LocalStorageKeyStorage(databaseKey: database.calls, identitySecret: identity.calls, randomSecret: randomSecret)
}

/// A friend as the LocalStorage provider reads one.
func localStoragePerson(
    id: String,
    name: String,
    latitude: Double = 40.7,
    timestamp: Date? = Date(timeIntervalSince1970: 1_700_000_000)
) -> LocalStoragePerson {
    LocalStoragePerson(
        serverIdentifier: id,
        displayName: name,
        fix: LocalStoragePersonFix(
            latitude: latitude,
            longitude: -73.9,
            horizontalAccuracy: 12,
            timestamp: timestamp,
            verticalAccuracy: 8,
            altitude: 25,
            speed: 1.5,
            course: 90,
            motionActivityState: 2,
            locationLabel: "Work"
        ),
        source: "findmylocateagent-localstorage"
    )
}
