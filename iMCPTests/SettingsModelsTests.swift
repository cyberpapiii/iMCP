import XCTest
@testable import iMCP

final class SettingsModelsTests: XCTestCase {
    func testMissingPermissionsComeFirstAndTheRestKeepTheirOrder() {
        let statuses: [String: ServicePermissionStatus] = [
            "calendar": .granted,
            "contacts": .notGranted,
            "location": .checking,
            "messages": .notEnabled,
            "reminders": .notGranted,
        ]
        XCTAssertEqual(
            missingFirst(["calendar", "contacts", "location", "messages", "reminders"]) { statuses[$0]! },
            ["contacts", "reminders", "calendar", "location", "messages"]
        )
    }

    func testAnAppWidePermissionIsCheckingUntilItIsKnown() {
        XCTAssertEqual(ServicePermissionStatus(granted: nil), .checking)
        XCTAssertEqual(ServicePermissionStatus(granted: true), .granted)
        XCTAssertEqual(ServicePermissionStatus(granted: false), .notGranted)
    }

    func testUnpairingOneClientNamesItAndSaysWhatIsLost() {
        let client = PairedClient(
            fingerprint: "abc123",
            label: "Example Agent",
            addedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(
            UnpairRequest.clients([client]),
            UnpairRequest(
                fingerprints: ["abc123"],
                title: "Unpair Client?",
                message: "Example Agent will have to ask for approval again before it can connect.",
                confirmLabel: "Unpair"
            )
        )
    }

    func testUnpairingSeveralClientsCountsThem() {
        let clients = ["a", "b"].map {
            PairedClient(fingerprint: $0, label: "Agent \($0)", addedAt: Date(timeIntervalSince1970: 0))
        }
        let request = UnpairRequest.clients(clients)
        XCTAssertEqual(request?.fingerprints, ["a", "b"])
        XCTAssertEqual(request?.title, "Unpair 2 Clients?")
        XCTAssertEqual(request?.message, "They will have to ask for approval again before they can connect.")
        XCTAssertEqual(request?.confirmLabel, "Unpair")
    }

    func testUnpairingNothingAsksNothing() {
        XCTAssertNil(UnpairRequest.clients([]))
    }

    func testUnpairingAnUnnamedClientStillReadsAsASentence() {
        let client = PairedClient(fingerprint: "abc123", label: "", addedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(
            UnpairRequest.clients([client])?.message,
            "This client will have to ask for approval again before it can connect."
        )
    }

    func testSettingsPutsAnICloudCodeFirst() {
        let code = ServicePermissionStatus(
            ICloudStatus.report(state: .awaitingCode(.trustedDevice), lastRenewedAt: nil)
        )
        XCTAssertEqual(
            missingFirst(["fullDiskAccess", "iCloud"]) { $0 == "iCloud" ? code : .granted },
            ["iCloud", "fullDiskAccess"]
        )
    }

    func testBackAndForwardRetraceThePagesVisited() {
        var history = SettingsHistory()
        XCTAssertFalse(history.canGoBack)
        history.visit(.general)
        history.visit(.clients)
        XCTAssertEqual(history.back(), .general)
        XCTAssertEqual(history.back(), .overview)
        XCTAssertFalse(history.canGoBack)
        XCTAssertEqual(history.back(), .overview, "Back at the first page stays there")
        XCTAssertEqual(history.forward(), .general)
        XCTAssertEqual(history.forward(), .clients)
        XCTAssertFalse(history.canGoForward)
    }

    func testANewPageAfterGoingBackDropsThePagesAhead() {
        var history = SettingsHistory()
        history.visit(.general)
        history.visit(.clients)
        _ = history.back()
        history.visit(.about)
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.back(), .general)
    }

    /// Back and Forward set the selection, and the selection change visits
    /// the page again. That visit must not count as a new one.
    func testVisitingThePageShownRecordsNothing() {
        var history = SettingsHistory()
        history.visit(.general)
        let shown = history.back()
        history.visit(shown)
        XCTAssertTrue(history.canGoForward)
    }

    func testSearchFindsAPageByWhatIsOnIt() {
        XCTAssertEqual(SettingsPane.allCases.filter { $0.matches("login") }, [.general])
        XCTAssertEqual(SettingsPane.allCases.filter { $0.matches("Full Disk") }, [.permissions])
        XCTAssertEqual(SettingsPane.allCases.filter { $0.matches("find my") }, [.location])
        XCTAssertEqual(SettingsPane.allCases.filter { $0.matches("  ") }, SettingsPane.allCases)
        XCTAssertTrue(SettingsPane.allCases.filter { $0.matches("zebra") }.isEmpty)
    }
}
