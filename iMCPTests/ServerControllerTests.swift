import XCTest

@testable import iMCP

/// The controller applies every switch write itself, with no view involved,
/// in the order the writes were made.
@MainActor
final class ServerControllerTests: XCTestCase {
    /// Named like the Utilities service, because a service's id is its type
    /// name: the Utilities switch drives this stand-in's lifecycle.
    actor UtilitiesService: Service {
        private(set) var changes: [Bool] = []

        nonisolated let tools: [Tool] = []

        func enablementDidChange(enabled: Bool) async {
            changes.append(enabled)
        }
    }

    private func makeController(defaults: UserDefaults, entries: [ServiceEntry] = []) -> ServerController {
        ServerController(
            networkManager: makeServerNetworkManager(
                storage: InMemoryKeychainItem(failSave: true).pairedClientStorage,
                prompt: { _ in .denied }
            ),
            entries: entries,
            defaults: defaults
        )
    }

    func testEverySwitchWriteReachesTheGateAndTheServiceInOrder() async throws {
        let defaults = makeTemporaryDefaults()
        let service = UtilitiesService()
        let entry = ServiceEntry(
            service: service,
            name: "Utilities",
            enabledKey: "utilitiesEnabled",
            defaultEnabled: true
        )
        let controller = makeController(defaults: defaults, entries: [entry])
        let utilities = try XCTUnwrap(controller.serviceSwitches.first { $0.id == ServiceEntry.id(of: service) })

        await controller.settle()
        var gate = await controller.networkManager.enabledServiceIDs
        XCTAssertTrue(gate.contains(utilities.id), "Utilities is on by default")

        utilities.isEnabled = false
        utilities.isEnabled = true
        utilities.isEnabled = false
        await controller.settle()

        gate = await controller.networkManager.enabledServiceIDs
        XCTAssertFalse(gate.contains(utilities.id))
        XCTAssertEqual(defaults.object(forKey: "utilitiesEnabled") as? Bool, false)
        let changes = await service.changes
        XCTAssertEqual(changes, [true, false, true, false])
    }

    func testTheMasterSwitchIsSavedUnderItsKey() async {
        let defaults = makeTemporaryDefaults()
        let controller = makeController(defaults: defaults)
        XCTAssertTrue(controller.isServerEnabled, "On by default")

        controller.isServerEnabled = false
        await controller.settle()

        XCTAssertEqual(defaults.object(forKey: "isEnabled") as? Bool, false)
        XCTAssertFalse(makeController(defaults: defaults).isServerEnabled)
    }

    func testLocationIsOnOnlyWhileItsSwitchIs() async throws {
        let entry = ServiceEntry(
            service: UtilitiesService(),
            name: "Location",
            enabledKey: "locationEnabled",
            defaultEnabled: false,
            isLocation: true
        )
        let controller = makeController(defaults: makeTemporaryDefaults(), entries: [entry])
        let location = try XCTUnwrap(controller.serviceSwitches.first)

        location.isEnabled = true
        XCTAssertTrue(controller.isLocationEnabled)
        location.isEnabled = false
        XCTAssertFalse(controller.isLocationEnabled)
        await controller.settle()
    }
}
