import Foundation
import SQLite3
import SRP
import XCTest

@testable import iMCP

func accountLoginBody(includeFindMy: Bool = true) -> [String: Any] {
    var services: [String: Any] = [
        "reminders": ["url": "https://p42-remindersws.icloud.com:443", "status": "active"]
    ]
    if includeFindMy {
        services["findme"] = ["url": "https://p42-fmipweb.icloud.com:443", "status": "active"]
    }
    return ["dsInfo": ["dsid": "12345"], "webservices": services]
}

/// The salt and B below are arbitrary well-formed values. The point of these
/// tests is the flow around SRP, not SRP itself, which `ICloudSRPTests` covers.
let challengeBody: [String: Any] = [
    "salt": Data(repeating: 0x11, count: 16).base64EncodedString(),
    "b": Data(repeating: 0x22, count: 256).base64EncodedString(),
    "c": "challenge-cookie",
    "iteration": 20,
    "protocol": "s2k",
]

/// A credential storage over a fresh in-memory item, and a read of what it
/// holds. Make an `InMemoryKeychainItem` directly to make it fail.
func storageInMemory() -> (ICloudCredentialStorage, () -> Data?) {
    let item = InMemoryKeychainItem()
    return (item.iCloudCredentialStorage, { item.data })
}

func storedWebAuthCookie(_ value: String) -> ICloudStoredCookie {
    ICloudStoredCookie(name: "X-APPLE-WEBAUTH-TOKEN", value: value, domain: ".icloud.com", path: "/", expiresAt: nil)
}

extension ICloudCredentialStorage {
    /// Plants `credentials` as the stored record, whatever was there. The app
    /// writes only through `update`; this is that call for a test's setup.
    @discardableResult
    func save(_ credentials: ICloudCredentials) async -> Bool {
        do {
            return try await update { _ in credentials } != nil
        } catch {
            return false
        }
    }
}
