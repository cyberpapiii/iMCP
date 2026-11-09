import AppKit
import Combine
import XCTest

@testable import iMCP

/// The menu's status rows are the answer to "why is this not working", so
/// their wording is pinned here rather than left to the view.
final class AppStatusTests: XCTestCase {
    private func appStatus(
        fullDiskAccessGranted: Bool? = true,
        fullDiskAccessNames: [String] = ["Messages"],
        locationEnabled: Bool = true,
        listenerFailed: Bool = false,
        iCloud: ICloudSession.State = .signedIn(accountName: "user@example.com"),
        pairedCount: Int? = 2
    ) -> AppStatus {
        AppStatus(
            fullDiskAccessGranted: fullDiskAccessGranted,
            fullDiskAccessNames: fullDiskAccessNames,
            fullDiskAccessCapableNames: ["Messages", "Notes"],
            locationEnabled: locationEnabled,
            listenerFailed: listenerFailed,
            iCloud: ICloudStatus.report(state: iCloud, lastRenewedAt: nil),
            clients: ClientsStatus.summary(pairedCount: pairedCount)
        )
    }

    func testOverallStatusIsFineWhenEveryRowIs() {
        let overall = appStatus().overall
        XCTAssertEqual(overall.level, .ok)
        XCTAssertEqual(overall.headline, "Everything is working")
    }

    func testOverallStatusIsFineWithNoPairedClients() {
        XCTAssertEqual(appStatus(pairedCount: 0).overall.level, .ok)
    }

    func testOverallStatusTakesTheWorstRowAndNamesIt() {
        let overall = appStatus(fullDiskAccessGranted: false, iCloud: .needsReauthentication).overall
        XCTAssertEqual(overall.level, .problem)
        XCTAssertEqual(overall.headline, "iCloud: Sign in to iCloud, and 1 more")

        let oneThing = appStatus(fullDiskAccessGranted: false).overall
        XCTAssertEqual(oneThing.level, .attention)
        XCTAssertEqual(oneThing.headline, "Full Disk Access: Needed by Messages")

        let unreadable = appStatus(pairedCount: nil).overall
        XCTAssertEqual(unreadable.level, .attention)
    }

    func testRowsThatDoNotApplyDoNotCount() {
        let locationOff = appStatus(locationEnabled: false, iCloud: .signedOut)
        XCTAssertEqual(locationOff.rows.map(\.title), ["Full Disk Access", "Clients"])
        XCTAssertEqual(locationOff.overall.level, .ok)

        let nothingNeedsTheGrant = appStatus(fullDiskAccessGranted: false, fullDiskAccessNames: [])
        XCTAssertEqual(nothingNeedsTheGrant.rows.map(\.title), ["iCloud", "Clients"])
        XCTAssertEqual(nothingNeedsTheGrant.overall.level, .ok)
        XCTAssertEqual(nothingNeedsTheGrant.fullDiskAccess?.detail, "Needed by Messages and Notes")

        let notCheckedYet = appStatus(fullDiskAccessGranted: nil)
        XCTAssertEqual(notCheckedYet.rows.map(\.title), ["iCloud", "Clients"])
    }

    /// The menu stays quiet while everything is fine and lists only what
    /// needs the owner otherwise. Settings keeps the healthy details.
    func testMenuListsOnlyTheRowsThatNeedTheOwner() {
        XCTAssertEqual(appStatus().rowsNeedingOwner, [])
        XCTAssertEqual(
            appStatus().rows.map(\.detail),
            ["Needed by Messages", "user@example.com · signed in", "2 paired clients"]
        )

        let troubled = appStatus(fullDiskAccessGranted: false, iCloud: .needsReauthentication)
        XCTAssertEqual(troubled.rowsNeedingOwner.map(\.subject), [.fullDiskAccess, .iCloud])
        XCTAssertEqual(
            troubled.rowsNeedingOwner.map(\.summary.detail),
            ["Needed by Messages", "Sign in to iCloud"]
        )

        XCTAssertEqual(appStatus(pairedCount: nil).rowsNeedingOwner.map(\.subject), [.clients])
        XCTAssertEqual(appStatus(locationEnabled: false, iCloud: .signedOut).rowsNeedingOwner, [])
    }

    /// A listener that could not be made is the first thing the menu says,
    /// and the icon does not show iMCP as fine while no client can connect.
    func testAFailedListenerIsTheFirstRowAndAProblem() {
        let failed = appStatus(fullDiskAccessGranted: false, listenerFailed: true)
        XCTAssertEqual(failed.rowsNeedingOwner.map(\.subject), [.server, .fullDiskAccess])
        XCTAssertEqual(failed.overall.level, .problem)
        XCTAssertEqual(
            failed.overall.headline,
            "Server: Clients cannot connect; turn iMCP off and on again, and 1 more"
        )
        XCTAssertEqual(MenuBarIndicator(serverEnabled: true, overall: failed.overall).icon, .attention)
        XCTAssertFalse(appStatus().subjectRows.map(\.subject).contains(.server))
    }

    /// Colour is not the only signal: each level draws its own symbol, and a
    /// misspelt name would draw nothing.
    func testEachStatusLevelHasItsOwnIconSoColourIsNotTheOnlySignal() {
        let symbols = [StatusSummary.Level.ok, .attention, .problem].map(\.symbolName)
        XCTAssertEqual(Set(symbols).count, symbols.count)
        for symbol in symbols {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }

    func testMenuBarIndicatorShowsTheDotOnlyWhileOnAndTroubled() {
        let fine = appStatus().overall
        let troubled = appStatus(iCloud: .needsReauthentication).overall
        let waiting = appStatus(iCloud: .working).overall

        XCTAssertEqual(MenuBarIndicator(serverEnabled: true, overall: fine).icon, .on)
        XCTAssertEqual(
            MenuBarIndicator(serverEnabled: true, overall: fine).accessibilityDescription,
            "iMCP is on. Everything is working"
        )
        XCTAssertEqual(MenuBarIndicator(serverEnabled: true, overall: troubled).icon, .attention)
        XCTAssertEqual(
            MenuBarIndicator(serverEnabled: true, overall: troubled).accessibilityDescription,
            "iMCP needs attention. iCloud: Sign in to iCloud"
        )
        XCTAssertEqual(MenuBarIndicator(serverEnabled: true, overall: waiting).icon, .attention)
        XCTAssertEqual(MenuBarIndicator(serverEnabled: false, overall: troubled).icon, .off)
        XCTAssertEqual(
            MenuBarIndicator(serverEnabled: false, overall: troubled).accessibilityDescription,
            "iMCP is off"
        )
    }

    /// A database service that is out of reach until its picker is used.
    private final class DatabaseService: Service {
        var reachable = false
        let tools: [Tool] = []

        var permission: ServicePermission { .fullDiskAccess(hasPicker: true) }

        var isActivated: Bool {
            get async { reachable }
        }

        func activate() async throws {
            reachable = true
        }
    }

    private func serviceSwitch(_ service: any Service, named name: String, isOn: @escaping () -> Bool = { true })
        -> ServiceSwitch
    {
        ServiceSwitch(
            entry: ServiceEntry(service: service, name: name, enabledKey: "unused", defaultEnabled: true),
            isEnabled: isOn,
            setEnabled: { _ in }
        )
    }

    @MainActor
    private func statusModel(
        switches: [ServiceSwitch],
        fullDiskAccessGranted: @escaping @MainActor () -> Bool?,
        grantMayHaveChanged: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher()
    ) -> AppStatusModel {
        AppStatusModel(
            sources: AppStatusModel.Sources(
                switches: { switches },
                locationEnabled: { false },
                iCloud: { _ in ICloudStatus.report(state: .signedOut, lastRenewedAt: nil) },
                pairedClientCount: { 1 },
                fullDiskAccessGranted: fullDiskAccessGranted,
                listenerFailed: { false }
            ),
            grantMayHaveChanged: grantMayHaveChanged
        )
    }

    /// The shared status knows about Full Disk Access without a window being
    /// opened: it checks when it is created, and again when it is told a
    /// service was switched or the app came forward.
    @MainActor
    func testSharedStatusChecksTheGrantAtStartAndWhenItMayHaveChanged() async {
        var granted = false
        let mayHaveChanged = PassthroughSubject<Void, Never>()
        let model = statusModel(
            switches: [serviceSwitch(DatabaseService(), named: "Messages")],
            fullDiskAccessGranted: { granted },
            grantMayHaveChanged: mayHaveChanged.eraseToAnyPublisher()
        )
        XCTAssertNil(model.status.fullDiskAccessGranted)
        await model.settle()
        XCTAssertEqual(model.status.fullDiskAccess?.level, .attention)
        XCTAssertEqual(model.status.overall.headline, "Full Disk Access: Needed by Messages")

        granted = true
        mayHaveChanged.send()
        await model.settle()
        XCTAssertEqual(model.status.fullDiskAccess?.level, .ok)
        XCTAssertEqual(model.status.overall.level, .ok)
    }

    /// Choosing the Messages database from a Grant button opens no other
    /// app, so the app never comes forward again to set off a check. The
    /// grant itself must reach the menu badge, the Settings row, and the Full
    /// Disk Access row, which all read one answer.
    @MainActor
    func testAGrantMadeAnywhereReachesEverySurfaceWithoutARefresh() async {
        let messages = serviceSwitch(DatabaseService(), named: "Messages")
        let model = statusModel(switches: [messages], fullDiskAccessGranted: { false })
        await model.settle()
        XCTAssertEqual(model.status.serviceAccess, [messages.id: false])
        XCTAssertEqual(model.status.fullDiskAccessGranted, false)

        await GuidanceRouter(status: model, showICloudSignIn: {}).grantAccess(to: messages)

        XCTAssertEqual(model.status.serviceAccess, [messages.id: true])
        XCTAssertEqual(model.status.fullDiskAccessGranted, true)
        XCTAssertEqual(model.status.overall.level, .ok)
        await model.settle()
        XCTAssertEqual(model.status.serviceAccess, [messages.id: true], "the re-check agrees")
    }

    /// Switching a service on asks for its access. A refusal snaps the
    /// switch back off, except for the permissions whose badge leads to the
    /// grant and shows only while the service is on.
    @MainActor
    func testSwitchingOnAsksForAccessAndARefusalSnapsTheSwitchOff() async {
        let cases: [(permission: ServicePermission, staysOn: Bool)] = [
            (.fullDiskAccess(hasPicker: true), false),
            (.capture, true),
            (.iCloudSignIn, true),
        ]
        for (permission, staysOn) in cases {
            let service = RefusingService(permission)
            var isOn = false
            let model = statusModel(switches: [], fullDiskAccessGranted: { nil })
            let router = GuidanceRouter(status: model, showICloudSignIn: {})

            let request = router.switchOn(storedSwitch(service, isOn: { isOn }, setOn: { isOn = $0 }))
            XCTAssertTrue(isOn, "the switch turns on before access is asked for")
            await request?.value

            XCTAssertEqual(service.requests, 1)
            XCTAssertEqual(isOn, staysOn, "\(permission)")
        }
    }

    /// A service whose access is already known to be granted is switched on
    /// without asking again.
    @MainActor
    func testSwitchingOnAServiceKnownToBeGrantedAsksForNothing() async {
        let service = RefusingService(.fullDiskAccess(hasPicker: true))
        service.reachable = true
        var isOn = true
        let serviceSwitch = storedSwitch(service, isOn: { isOn }, setOn: { isOn = $0 })
        let model = statusModel(switches: [serviceSwitch], fullDiskAccessGranted: { nil })
        await model.settle()
        XCTAssertEqual(model.status.serviceAccess, [serviceSwitch.id: true])

        isOn = false
        XCTAssertNil(GuidanceRouter(status: model, showICloudSignIn: {}).switchOn(serviceSwitch))

        XCTAssertTrue(isOn)
        XCTAssertEqual(service.requests, 0)
    }

    /// A service whose `activate()` always fails, counting each request.
    private final class RefusingService: Service {
        let permission: ServicePermission
        var reachable = false
        var requests = 0
        let tools: [Tool] = []

        init(_ permission: ServicePermission) {
            self.permission = permission
        }

        var isActivated: Bool {
            get async { reachable }
        }

        func activate() async throws {
            requests += 1
            throw ToolFailure("refused")
        }
    }

    private func storedSwitch(
        _ service: any Service,
        isOn: @escaping () -> Bool,
        setOn: @escaping (Bool) -> Void
    ) -> ServiceSwitch {
        ServiceSwitch(
            entry: ServiceEntry(service: service, name: "Service", enabledKey: "unused", defaultEnabled: true),
            isEnabled: isOn,
            setEnabled: setOn
        )
    }

    /// The grant itself, or every dependent service that is on reaching its
    /// database through the file it was given. A service that is off has no
    /// answer to show, and none to stand in for the grant.
    @MainActor
    func testFullDiskAccessIsTheGrantOrEveryDependentReachingItsData() async {
        var isOn = true
        let service = DatabaseService()
        let messages = serviceSwitch(service, named: "Messages", isOn: { isOn })
        var granted = true
        let model = statusModel(switches: [messages], fullDiskAccessGranted: { granted })
        await model.settle()
        XCTAssertEqual(model.status.fullDiskAccessGranted, true)

        granted = false
        service.reachable = true
        model.refresh()
        await model.settle()
        XCTAssertEqual(model.status.fullDiskAccessGranted, true)

        isOn = false
        model.refresh()
        await model.settle()
        XCTAssertEqual(model.status.serviceAccess, [:])
        XCTAssertEqual(model.status.fullDiskAccessGranted, false)
    }

    func testFullDiskAccessRowNamesTheServices() {
        let needed = FullDiskAccessStatus.summary(requiredBy: ["Messages", "Notes"], granted: false)
        XCTAssertEqual(needed.level, .attention)
        XCTAssertEqual(needed.detail, "Needed by Messages and Notes")
        XCTAssertEqual(FullDiskAccessStatus.summary(requiredBy: ["Messages"], granted: true).level, .ok)
    }

    func testClientsRowCounts() {
        XCTAssertEqual(
            ClientsStatus.summary(pairedCount: 0).detail,
            "No paired clients yet. Each connection asks for your approval."
        )
        XCTAssertEqual(ClientsStatus.summary(pairedCount: 1).detail, "1 paired client")
        XCTAssertEqual(ClientsStatus.summary(pairedCount: 3).detail, "3 paired clients")

        let unreadable = ClientsStatus.summary(pairedCount: nil)
        XCTAssertEqual(unreadable.level, .attention)
        XCTAssertEqual(unreadable.detail, "Could not read paired clients. Unlock your Mac's keychain")
    }

    func testFullDiskAccessSettingsWordsAddWhereToGrantOnlyWhileMissing() {
        XCTAssertEqual(
            FullDiskAccessStatus.explanation(requiredBy: ["Messages"], needsOwner: true),
            "Needed by Messages. Allow iMCP in System Settings > Privacy & Security > Full Disk Access."
        )
        XCTAssertEqual(
            FullDiskAccessStatus.explanation(requiredBy: ["Messages"], needsOwner: false),
            "Needed by Messages"
        )
    }

    // MARK: - Where each row leads

    func testEachRowCarriesWhereItLeadsAndSaysSoToVoiceOver() {
        let status = appStatus(fullDiskAccessGranted: false, iCloud: .needsReauthentication, pairedCount: nil)
        XCTAssertEqual(status.rowsNeedingOwner.map(\.destination), [.fullDiskAccessPane, .iCloudSignIn, .settings])
        XCTAssertEqual(
            status.rowsNeedingOwner.map(\.hint),
            ["Opens Full Disk Access in System Settings", "Opens the iCloud sign-in window", "Opens Settings"]
        )
    }

}
