import Foundation
import SQLite3
import SRP
import XCTest

@testable import iMCP

/// Find My's payload is loosely typed and Apple changes it without notice, so
/// the decoding and the person-grouping are pinned here against a recorded
/// shape rather than discovered live.
final class FindMyClientTests: XCTestCase {
    private let account = try! ICloudAccount(
        dsid: "1234",
        webservices: ["findme": URL(string: "https://p1-fmipweb.icloud.com")!]
    )

    private func makeClient(
        _ transport: ScriptedTransport,
        didSucceed: FindMyClientEvents.Hook? = nil,
        onRejected: FindMyClientEvents.Hook? = nil
    ) -> FindMyClient {
        let client = FindMyClient(transport: transport, account: account, clientID: "client-id")
        client.events.attach(didSucceed: didSucceed, onRejected: onRejected)
        return client
    }

    private var deviceListJSON: [String: Any] {
        [
            "serverContext": ["prsId": 1234, "deviceLoadStatus": "200"],
            "userInfo": [
                "firstName": "Robin", "lastName": "Doe",
                "membersInfo": [
                    "family-1": ["firstName": "Sam", "lastName": "Doe"]
                ],
            ],
            "content": [
                [
                    "id": "phone",
                    "name": "Robin's iPhone",
                    "deviceDisplayName": "iPhone 15 Pro",
                    "deviceClass": "iPhone",
                    "batteryLevel": 0.62,
                    "batteryStatus": "NotCharging",
                    "thisDevice": false,
                    "features": ["SND": true],
                    "location": [
                        "latitude": 40.7128,
                        "longitude": -74.006,
                        "horizontalAccuracy": 12.0,
                        "timeStamp": 1_700_000_000_000,
                        "positionType": "GPS",
                        "isOld": false,
                    ],
                ],
                [
                    "id": "mac",
                    "name": "Robin's Mac",
                    "deviceClass": "Mac",
                    "thisDevice": true,
                    "features": ["SND": false],
                    "location": [
                        "latitude": 40.0,
                        "longitude": -74.0,
                        "horizontalAccuracy": 3.0,
                        // An hour older than the phone, and more accurate, so
                        // this is the tie-break case: recency has to win.
                        "timeStamp": 1_699_996_400_000,
                        "isOld": true,
                    ],
                ],
                [
                    "id": "sam-phone",
                    "name": "Sam's iPhone",
                    "deviceClass": "iPhone",
                    "prsId": "family-1",
                    "features": ["SND": true],
                ],
            ],
        ]
    }

    func testDevicesAndFamilyMembersAreDecodedFromTheDeviceList() async throws {
        let transport = ScriptedTransport()
        transport.stub("initClient", json: deviceListJSON)

        let snapshot = try await makeClient(transport).snapshot()

        XCTAssertEqual(snapshot.devices.count, 3)
        let phone = try XCTUnwrap(snapshot.devices.first { $0.id == "phone" })
        XCTAssertEqual(phone.model, "iPhone 15 Pro")
        XCTAssertEqual(phone.batteryLevel, 0.62)
        XCTAssertTrue(phone.canPlaySound)
        XCTAssertEqual(phone.location?.latitude, 40.7128)
        XCTAssertEqual(
            phone.location?.timestamp,
            Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(snapshot.people.map(\.name), ["Robin Doe", "Sam Doe"])
        let me = try XCTUnwrap(snapshot.people.first)
        XCTAssertTrue(me.isMe)
        XCTAssertEqual(me.devices.count, 2)
        // The Mac's fix is tighter but older; a person is where they were most
        // recently seen.
        XCTAssertEqual(me.bestFix?.device.id, "phone")

        let family = try XCTUnwrap(snapshot.people.last)
        XCTAssertFalse(family.isMe)
        XCTAssertNil(family.bestFix)
    }

    func testTheSecondCallRefreshesWithApplesServerContext() async throws {
        let transport = ScriptedTransport()
        transport.stub("initClient", json: deviceListJSON)
        transport.stub("refreshClient", json: deviceListJSON)
        let client = makeClient(transport)

        _ = try await client.snapshot()
        _ = try await client.snapshot(locate: true)

        let refresh = try XCTUnwrap(transport.requests(matching: "refreshClient").first)
        XCTAssertNotNil(refresh.json["serverContext"])
        XCTAssertEqual(refresh.json["isUpdatingAllLocations"] as? Bool, true)
        let context = try XCTUnwrap(refresh.json["clientContext"] as? [String: Any])
        XCTAssertEqual(context["shouldLocate"] as? Bool, true)
        XCTAssertEqual(context["selectedDevice"] as? String, "all")
        // The service endpoints authenticate by cookie and reject the sign-in
        // header set, so these calls must look like the web client.
        XCTAssertEqual(refresh.header("Origin"), "https://www.icloud.com")
        XCTAssertNil(refresh.header("X-Apple-ID-Session-Id"))
    }

    func testRefreshCanTargetOnlyTheUsersPhone() async throws {
        let transport = ScriptedTransport()
        transport.stub("initClient", json: deviceListJSON)
        transport.stub("refreshClient", json: deviceListJSON)
        let client = makeClient(transport)

        _ = try await client.snapshot()
        _ = try await client.snapshot(locate: true, selectedDeviceID: "phone")

        let refresh = try XCTUnwrap(transport.requests(matching: "refreshClient").first)
        let context = try XCTUnwrap(refresh.json["clientContext"] as? [String: Any])
        XCTAssertEqual(context["selectedDevice"] as? String, "phone")
    }

    func testARejectedRefreshContextReinitializesBeforeExpiringTheAccountSession() async throws {
        let transport = ScriptedTransport()
        transport.stub("initClient", json: deviceListJSON)
        transport.stub("refreshClient", status: 450)
        var reinitializedJSON = deviceListJSON
        reinitializedJSON["serverContext"] = ["prsId": 5678, "deviceLoadStatus": "200"]
        transport.stub("initClient", json: reinitializedJSON)
        transport.stub("refreshClient", json: reinitializedJSON)
        let client = makeClient(transport)

        _ = try await client.snapshot()
        let recovered = try await client.snapshot(locate: true, selectedDeviceID: "phone")

        XCTAssertEqual(recovered.devices.count, 3)
        XCTAssertEqual(transport.requests(matching: "initClient").count, 2)
        XCTAssertEqual(transport.requests(matching: "refreshClient").count, 2)
        let recoveredLocate = try XCTUnwrap(transport.requests(matching: "refreshClient").last)
        let recoveredServerContext = try XCTUnwrap(recoveredLocate.json["serverContext"] as? [String: Any])
        XCTAssertEqual(recoveredServerContext["prsId"] as? Int, 5678)
        let context = try XCTUnwrap(recoveredLocate.json["clientContext"] as? [String: Any])
        XCTAssertEqual(context["shouldLocate"] as? Bool, true)
        XCTAssertEqual(context["selectedDevice"] as? String, "phone")
        XCTAssertEqual(
            transport.requests(matching: "fmipservice").map(\.path).map {
                URL(fileURLWithPath: $0).lastPathComponent
            },
            ["initClient", "refreshClient", "initClient", "refreshClient"]
        )
    }

    /// Apple can retire an iCloud web build while the browser cookies remain valid.
    /// A 450 must refresh Apple's published build identifiers before the session
    /// escalates to password authentication and its account notification.
    func testARejectedBuildRefreshesPublishedVersionBeforeExpiringSession() async throws {
        let transport = ScriptedTransport()
        transport.stubWebClientVersions([
            ICloudWebClientVersion(buildNumber: "2534Project66", masteringNumber: "2534B22"),
            ICloudWebClientVersion(buildNumber: "2640Build24", masteringNumber: "2640Build24"),
        ])
        transport.stub("initClient", status: 450)
        transport.stub("initClient", json: deviceListJSON)

        let snapshot = try await makeClient(transport).snapshot()

        XCTAssertEqual(snapshot.devices.count, 3)
        let requests = transport.requests(matching: "initClient")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests.compactMap { request in
                URLComponents(url: request.request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "clientBuildNumber" }?.value
            },
            ["2534Project66", "2640Build24"]
        )
        XCTAssertEqual(transport.webClientVersionRefreshes, [false, true])
    }

    func testARejectedRefreshContextReinitializesOnlyOnce() async throws {
        let transport = ScriptedTransport()
        transport.stub("initClient", json: deviceListJSON)
        transport.stub("refreshClient", status: 450)
        transport.stub("initClient", status: 450)
        let client = makeClient(transport)

        _ = try await client.snapshot()
        do {
            _ = try await client.snapshot(locate: true, selectedDeviceID: "phone")
            XCTFail("Expected the dead account session to expire")
        } catch {
            XCTAssertEqual(error as? ICloudAuthError, .trustExpired)
        }

        XCTAssertEqual(transport.requests(matching: "initClient").count, 2)
        XCTAssertEqual(transport.requests(matching: "refreshClient").count, 1)
    }

    func testARejectedNonLocateRefreshReinitializesWithoutAnotherRefresh() async throws {
        let transport = ScriptedTransport()
        transport.stub("initClient", json: deviceListJSON)
        transport.stub("refreshClient", status: 450)
        transport.stub("initClient", json: deviceListJSON)
        let client = makeClient(transport)

        _ = try await client.snapshot()
        let recovered = try await client.snapshot()

        XCTAssertEqual(recovered.devices.count, 3)
        XCTAssertEqual(transport.requests(matching: "initClient").count, 2)
        XCTAssertEqual(transport.requests(matching: "refreshClient").count, 1)
    }

    func testLocateAfterFailedReinitializationStillRequestsAFreshFix() async throws {
        let transport = ScriptedTransport()
        transport.stub("initClient", json: deviceListJSON)
        transport.stub("refreshClient", status: 450)
        let client = makeClient(transport)

        _ = try await client.snapshot()
        transport.fail("initClient", with: URLError(.timedOut))
        do {
            _ = try await client.snapshot(locate: true, selectedDeviceID: "phone")
            XCTFail("Expected reinitialization to fail")
        } catch {
            XCTAssertEqual(error as? URLError, URLError(.timedOut))
        }

        transport.stub("initClient", json: deviceListJSON)
        transport.stub("refreshClient", json: deviceListJSON)
        _ = try await client.snapshot(locate: true, selectedDeviceID: "phone")

        XCTAssertEqual(transport.requests(matching: "initClient").count, 3)
        XCTAssertEqual(transport.requests(matching: "refreshClient").count, 2)
        let located = try XCTUnwrap(transport.requests(matching: "refreshClient").last)
        let context = try XCTUnwrap(located.json["clientContext"] as? [String: Any])
        XCTAssertEqual(context["shouldLocate"] as? Bool, true)
        XCTAssertEqual(context["selectedDevice"] as? String, "phone")
    }

    func testConcurrentSnapshotsWaitForContextRecoveryToFinish() async throws {
        let transport = ScriptedTransport()
        transport.stub("initClient", json: deviceListJSON)
        transport.stub("refreshClient", status: 450)
        var recoveredJSON = deviceListJSON
        recoveredJSON["serverContext"] = ["prsId": 5678, "deviceLoadStatus": "200"]
        transport.stub("initClient", json: recoveredJSON)
        transport.stub("refreshClient", json: recoveredJSON)
        transport.stub("refreshClient", json: recoveredJSON)
        let client = makeClient(transport)

        _ = try await client.snapshot()
        transport.block("refreshClient")
        let first = Task { try await client.snapshot(locate: true, selectedDeviceID: "phone") }
        await transport.waitUntilBlocked("refreshClient")

        let secondStarted = expectation(description: "second snapshot started")
        let second = Task {
            secondStarted.fulfill()
            return try await client.snapshot(locate: true, selectedDeviceID: "phone")
        }
        await fulfillment(of: [secondStarted], timeout: 1)
        // No hook says the second snapshot is waiting, so give it every
        // chance to reach the transport while the first is held there.
        for _ in 0 ..< 100 { await Task.yield() }

        transport.resume("refreshClient")
        _ = try await first.value
        _ = try await second.value

        XCTAssertEqual(
            transport.requests(matching: "fmipservice").map { URL(fileURLWithPath: $0.path).lastPathComponent },
            ["initClient", "refreshClient", "initClient", "refreshClient", "refreshClient"],
            "the second snapshot starts only once the first has recovered"
        )
        let refreshes = transport.requests(matching: "refreshClient")
        let contexts = refreshes.map { ($0.json["serverContext"] as? [String: Any])?["prsId"] as? Int }
        XCTAssertEqual(contexts, [1234, 5678, 5678], "the second snapshot uses the recovered context")
        let located = refreshes.filter {
            ($0.json["clientContext"] as? [String: Any])?["shouldLocate"] as? Bool == true
        }
        XCTAssertEqual(located.count, 3)
    }

    func testIntermediateRecoverySuccessDoesNotClearTheAccountGuard() async throws {
        let transport = ScriptedTransport()
        transport.stub("initClient", json: deviceListJSON)
        transport.stub("refreshClient", status: 450)
        transport.stub("initClient", json: deviceListJSON)
        transport.stub("refreshClient", status: 450)
        let successes = Counter()
        let client = makeClient(transport, didSucceed: { successes.increment() })

        _ = try await client.snapshot()
        let initialSuccesses = successes.value
        XCTAssertEqual(initialSuccesses, 1)

        do {
            _ = try await client.snapshot(locate: true, selectedDeviceID: "phone")
            XCTFail("Expected the located refresh to reject the session")
        } catch {
            XCTAssertEqual(error as? ICloudAuthError, .trustExpired)
        }

        let finalSuccesses = successes.value
        XCTAssertEqual(
            finalSuccesses,
            1,
            "an accepted init inside a failed recovery must not mark the whole operation recovered"
        )

        transport.stub("initClient", json: deviceListJSON)
        transport.stub("refreshClient", json: deviceListJSON)
        _ = try await client.snapshot(locate: true, selectedDeviceID: "phone")
        XCTAssertEqual(
            transport.requests(matching: "initClient").count,
            3,
            "the next call must not reuse the server context Apple rejected"
        )
    }

    /// The session renews on the client's word, so the word has to arrive
    /// before the caller sees the rejection, and only for a rejection.
    func testARejectedSessionIsReportedBeforeTheCallThrows() async throws {
        let transport = ScriptedTransport()
        transport.stub("initClient", status: 421)
        let successes = Counter()
        let rejections = Counter()
        let client = makeClient(
            transport,
            didSucceed: { successes.increment() },
            onRejected: { rejections.increment() }
        )

        do {
            _ = try await client.snapshot()
            XCTFail("expected Apple to reject the session")
        } catch {
            XCTAssertEqual(error as? ICloudAuthError, .trustExpired)
        }

        XCTAssertEqual(rejections.value, 1)
        XCTAssertEqual(successes.value, 0)
    }

    func testSuccessfulOperationWaitsForItsSuccessCallback() async throws {
        let transport = ScriptedTransport()
        transport.stub("initClient", json: deviceListJSON)
        let events = EventLog()
        let callbackGate = AsyncGate()
        let client = makeClient(
            transport,
            didSucceed: {
                await callbackGate.wait()
                events.append("callback finished")
            }
        )

        let snapshot = Task {
            let value = try await client.snapshot()
            events.append("snapshot returned")
            return value
        }
        await callbackGate.waitUntilWaiting()
        // Gives a snapshot that does not wait for its callback time to return.
        for _ in 0 ..< 100 { await Task.yield() }
        await callbackGate.open()
        _ = try await snapshot.value

        XCTAssertEqual(
            events.all,
            ["callback finished", "snapshot returned"],
            "snapshot must not return before its success callback preserves session state"
        )
    }

    func testPlaySoundNamesTheDevice() async throws {
        let transport = ScriptedTransport()
        transport.stub("playSound", json: ["status": 200])

        try await makeClient(transport).playSound(deviceID: "phone")

        let request = try XCTUnwrap(transport.requests(matching: "playSound").first)
        XCTAssertEqual(request.json["device"] as? String, "phone")
        XCTAssertTrue(request.request.url?.query()?.contains("dsid=1234") == true)
    }

    func testASecondSoundOnTheSameDeviceIsRefusedWithoutARequest() async throws {
        let transport = ScriptedTransport()
        transport.stub("playSound", json: ["status": 200])
        transport.stub("playSound", json: ["status": 200])
        let client = makeClient(transport)

        try await client.playSound(deviceID: "phone")
        do {
            try await client.playSound(deviceID: "phone")
            XCTFail("Expected the cooldown to refuse")
        } catch {
            XCTAssertEqual(error as? FindMyError, .soundPlayedRecently)
        }
        XCTAssertEqual(transport.requests(matching: "playSound").count, 1)

        try await client.playSound(deviceID: "watch")
        XCTAssertEqual(transport.requests(matching: "playSound").count, 2)
    }

    /// A ring on a lapsed session must start the same renewal a snapshot
    /// would, and say so in words, not as an opaque error type.
    func testARejectedSoundIsReportedAsAnExpiredSession() async throws {
        let transport = ScriptedTransport()
        transport.stub("playSound", status: 421)
        transport.stub("playSound", json: ["status": 200])
        let successes = Counter()
        let rejections = Counter()
        let client = makeClient(
            transport,
            didSucceed: { successes.increment() },
            onRejected: { rejections.increment() }
        )

        do {
            try await client.playSound(deviceID: "phone")
            XCTFail("expected Apple to reject the session")
        } catch {
            XCTAssertEqual(error as? ICloudAuthError, .trustExpired)
            XCTAssertNotNil((error as? ICloudAuthError)?.errorDescription)
        }
        XCTAssertEqual(rejections.value, 1)
        XCTAssertEqual(successes.value, 0)
        // Nothing played, so the cooldown does not hold the retry back.
        try await client.playSound(deviceID: "phone")
        XCTAssertEqual(successes.value, 1)
    }

    /// A 450 can be a retired web build: the ring is retried once on a
    /// refreshed one before the session is called dead.
    func testASoundRejectedForTheWebBuildIsRetriedOnceWithAFreshBuild() async throws {
        let transport = ScriptedTransport()
        transport.stub("playSound", status: 450)
        transport.stub("playSound", json: ["status": 200])
        let rejections = Counter()
        let client = makeClient(transport, onRejected: { rejections.increment() })

        try await client.playSound(deviceID: "phone")

        XCTAssertEqual(transport.requests(matching: "playSound").count, 2)
        XCTAssertEqual(transport.webClientVersionRefreshes, [false, true])
        XCTAssertEqual(rejections.value, 0)

        let lapsed = ScriptedTransport()
        lapsed.stub("playSound", status: 450)
        lapsed.stub("playSound", status: 450)
        let lapsedRejections = Counter()
        let lapsedClient = makeClient(lapsed, onRejected: { lapsedRejections.increment() })
        do {
            try await lapsedClient.playSound(deviceID: "phone")
            XCTFail("expected Apple to reject the session")
        } catch {
            XCTAssertEqual(error as? ICloudAuthError, .trustExpired)
        }
        XCTAssertEqual(lapsedRejections.value, 1)
    }

    func testAFailedSoundDoesNotStartTheCooldown() async throws {
        let transport = ScriptedTransport()
        transport.stub("playSound", status: 500)
        transport.stub("playSound", json: ["status": 200])
        let client = makeClient(transport)

        do {
            try await client.playSound(deviceID: "phone")
            XCTFail("Expected Apple's rejection")
        } catch {
            XCTAssertEqual(error as? FindMyError, .appleRejectedRequest(status: 500))
        }
        try await client.playSound(deviceID: "phone")
    }

    func testRingingNeedsExactlyOneOfTheUsersOwnDevices() throws {
        func device(_ id: String, _ name: String, owner: String? = nil) -> FindMyDevice {
            FindMyDevice(
                id: id,
                name: name,
                model: nil,
                deviceClass: nil,
                batteryLevel: nil,
                batteryStatus: nil,
                isThisDevice: false,
                ownerID: owner,
                canPlaySound: true,
                location: nil
            )
        }
        let devices = [
            device("a", "iPhone"), device("b", "iPhone"), device("c", "Watch"),
            device("d", "Tablet", owner: "family-1"),
        ]

        XCTAssertEqual(try LocationPersonResolver.ownDevice(matching: "watch", in: devices).id, "c")
        XCTAssertEqual(try LocationPersonResolver.ownDevice(matching: "b", in: devices).id, "b")
        XCTAssertThrowsError(try LocationPersonResolver.ownDevice(matching: "iPhone", in: devices)) { error in
            let text = (error as? ToolInputError)?.message ?? ""
            XCTAssertTrue(text.contains("a, b"), text)
        }
        XCTAssertThrowsError(try LocationPersonResolver.ownDevice(matching: "Tablet", in: devices)) { error in
            XCTAssertEqual(error as? FindMyError, .unknownDevice("Tablet"))
        }
    }

    func testAFixWithoutATimestampIsNotAFix() async throws {
        let transport = ScriptedTransport()
        transport.stub(
            "initClient",
            json: [
                "serverContext": ["prsId": 1234],
                "content": [
                    ["id": "phone", "name": "Phone", "location": ["latitude": 40.7, "longitude": -74.0]]
                ],
            ]
        )

        let snapshot = try await makeClient(transport).snapshot()

        XCTAssertNil(snapshot.devices.first?.location)
    }

    func testADeadSessionIsReportedAsExpiredTrustNotAsARejection() async {
        let transport = ScriptedTransport()
        transport.stub("initClient", status: 421)

        do {
            _ = try await makeClient(transport).snapshot()
            XCTFail("Expected the call to fail")
        } catch {
            XCTAssertEqual(error as? ICloudAuthError, .trustExpired)
        }
    }

    func testAnAccountWithNoDevicesSaysSo() async {
        let transport = ScriptedTransport()
        transport.stub("initClient", json: ["content": [], "serverContext": [:]])

        do {
            _ = try await makeClient(transport).snapshot()
            XCTFail("Expected the call to fail")
        } catch {
            XCTAssertEqual(error as? FindMyError, .noDevices)
        }
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) { lock.withLock { entries.append(entry) } }
    var all: [String] { lock.withLock { entries } }
}
