import XCTest
@testable import iMCP

final class ServiceRegistryTests: XCTestCase {
    /// The switches' persisted keys. Weather is Debug-compiled-out of the list.
    func testEveryRegisteredServiceKeepsItsPersistedSwitchKey() {
        let expectedKeys = [
            "browserHistoryEnabled",
            "calendarEnabled",
            "callHistoryEnabled",
            "captureEnabled",
            "contactsEnabled",
            "locationEnabled",
            "mapsEnabled",
            "messagesEnabled",
            "notesEnabled",
            "notificationsEnabled",
            "photosEnabled",
            "remindersEnabled",
            "screenTimeEnabled",
            "shortcutsEnabled",
            "utilitiesEnabled",
        ]
        XCTAssertEqual(
            Set(ServiceRegistry.entries.map(\.enabledKey)),
            Set(expectedKeys)
        )
    }

    /// The IDs join the menu's toggles to the tool gate. They are type names,
    /// so renaming a service type must be a decision, not an accident.
    func testServiceIDsAreStable() {
        XCTAssertEqual(
            ServiceRegistry.entries.map(\.id),
            [
                "BrowserHistoryService", "CalendarService", "CallHistoryService",
                "CaptureService", "ContactsService", "LocationService", "MapsService",
                "MessageService", "NotesService", "NotificationsService", "PhotoService",
                "RemindersService", "ScreenTimeService", "ShortcutsService", "UtilitiesService",
            ]
        )
        XCTAssertEqual(ServiceRegistry.entries.filter(\.isLocation).map(\.id), ["LocationService"])
        XCTAssertEqual(ServiceRegistry.weather.id, "WeatherService")
    }

    /// The network core and the menu read a service's name from its entry;
    /// the menu reads its icon and color from the presentation. Every entry
    /// has one.
    func testEveryServiceHasAPresentation() {
        for entry in ServiceRegistry.entries + [ServiceRegistry.weather] {
            XCTAssertNotNil(ServicePresentation.table[entry.id], entry.id)
        }
        XCTAssertEqual(ServiceRegistry.entries.first { $0.id == "CalendarService" }?.name, "Calendar")
        XCTAssertEqual(ServiceRegistry.weather.name, "Weather")
    }

    private func switches(enabled: Bool) -> [ServiceSwitch] {
        ServiceRegistry.entries.map { ServiceSwitch(entry: $0, isEnabled: { enabled }, setEnabled: { _ in }) }
    }

    /// The services that need Full Disk Access say so through their own
    /// permission; Browser History has no file picker to offer.
    func testFullDiskAccessServicesAreTheOnesThatDeclareIt() {
        let configs = switches(enabled: true)
        XCTAssertEqual(
            ServiceSwitch.fullDiskAccessNames(from: configs),
            ["Browser History", "Call History", "Messages", "Notifications", "Screen Time"]
        )
        XCTAssertEqual(
            BrowserHistoryService.shared.permission.explanation,
            "Needs Full Disk Access to read this data. Allow iMCP in System Settings > Privacy & Security > "
                + "Full Disk Access."
        )
        XCTAssertTrue(
            MessageService.shared.permission.explanation?.hasSuffix("in the iMCP menu to choose its database.") == true
        )
    }

}
