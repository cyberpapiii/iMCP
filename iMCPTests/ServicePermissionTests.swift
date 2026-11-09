import XCTest

@testable import iMCP

final class ServicePermissionTests: XCTestCase {
    private final class PromptingService: Service {
        let activations = Counter()
        let permission: ServicePermission

        init(permission: ServicePermission) {
            self.permission = permission
        }

        func activate() async throws {
            activations.increment()
        }

        var tools: [Tool] {
            Tool(
                name: "probe",
                description: "probe",
                arguments: [],
                annotations: .init(title: "Probe", readOnlyHint: true, openWorldHint: false)
            ) { _ in Value.bool(true) }
        }
    }

    /// A first tool call is what raises the Calendar, Contacts, Photos, or
    /// Automation prompt; Full Disk Access and Capture never activate there.
    func testOnlyPromptablePermissionsActivateBeforeEveryToolCall() async throws {
        let prompting = PromptingService(permission: .contacts)
        _ = try await prompting.callableTools[0]([:])
        _ = try await prompting.callableTools[0]([:])
        XCTAssertEqual(prompting.activations.value, 2)

        for permission: ServicePermission in [.fullDiskAccess(hasPicker: true), .capture, .iCloudSignIn, .none] {
            let quiet = PromptingService(permission: permission)
            _ = try await quiet.callableTools[0]([:])
            XCTAssertEqual(quiet.activations.value, 0)
        }
    }

    func testGuidanceLeadsToThePermissionsOwnPane() {
        XCTAssertEqual(
            CalendarService.shared.permission.guidance,
            .systemSettings(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
        )
        XCTAssertEqual(
            RemindersService.shared.permission.guidance,
            .systemSettings(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!)
        )
        XCTAssertEqual(
            BrowserHistoryService.shared.permission.guidance,
            .systemSettings(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
        )
    }

    /// The badge is what to click; the Settings row has its own Grant button,
    /// so its words do not tell the owner to click them.
    func testSettingsWordsDoNotAskForAClickOnThemselves() {
        XCTAssertEqual(
            CalendarService.shared.permission.settingsDetail,
            "Needs Calendar access. You can also enable iMCP under Calendars in System Settings."
        )
        XCTAssertEqual(
            ServicePermission.capture.settingsDetail,
            "Needs Camera, Microphone, or Screen Recording access."
        )
        XCTAssertEqual(
            ServicePermission.iCloudSignIn.settingsDetail,
            "Needs an iCloud sign-in to see where your people and devices are."
        )
        XCTAssertEqual(
            ServicePermission.iCloudSignIn.explanation,
            "Needs an iCloud sign-in to see where your people and devices are. Click to sign in."
        )
        XCTAssertEqual(
            ServicePermission.fullDiskAccess(hasPicker: true).settingsDetail,
            ServicePermission.fullDiskAccess(hasPicker: true).explanation
        )
        XCTAssertNil(ServicePermission.none.settingsDetail)
    }

    /// The badge and the tool error say the same thing from one template.
    func testWordingComesFromOneTemplate() {
        XCTAssertEqual(
            CalendarService.shared.permission.explanation,
            "Needs Calendar access. Click to grant, or enable iMCP under Calendars in System Settings."
        )
        XCTAssertEqual(
            NotesService.shared.permission.explanation,
            "Needs Automation access to control Notes. Click to grant, or enable iMCP under Automation in System Settings."
        )
        XCTAssertEqual(
            ServicePermission.notGranted("Reminders", pane: "Reminders", fullAccess: true).message,
            "Reminders access is not granted. Allow iMCP full access in System Settings > Privacy & Security > Reminders."
        )
        XCTAssertEqual(
            ServicePermission.notGranted("Screen recording", pane: "Screen & System Audio Recording", note: "Restart.")
                .message,
            "Screen recording access is not granted. Allow iMCP in System Settings > Privacy & Security > "
                + "Screen & System Audio Recording. Restart."
        )
    }

    /// Each service throws its own permission's refusal; the words are the
    /// ones each one used to write out by hand.
    func testEachPromptedPermissionWordsItsOwnRefusal() {
        XCTAssertEqual(
            ContactsService.shared.permission.deniedError.message,
            "Contacts access is not granted. Allow iMCP in System Settings > Privacy & Security > Contacts."
        )
        XCTAssertEqual(
            PhotoService.shared.permission.deniedError.message,
            "Photos access is not granted. Allow iMCP in System Settings > Privacy & Security > Photos."
        )
        XCTAssertEqual(
            NotesService.shared.permission.deniedError.message,
            "Notes automation access is not granted. Allow iMCP in System Settings > Privacy & Security > Automation."
        )
        XCTAssertEqual(
            CalendarService.shared.permission.deniedError.message,
            "Calendar access is not granted. Allow iMCP full access in System Settings > Privacy & Security > "
                + "Calendars."
        )
    }

    /// The Settings row, the badge, the status line, and every Full Disk
    /// Access tool error give one instruction, in the words every other
    /// permission's tool error uses.
    func testFullDiskAccessHasOneInstruction() {
        let instruction = "Allow iMCP in System Settings > Privacy & Security > Full Disk Access."
        XCTAssertEqual(ServicePermission.fullDiskAccessGrantInstruction, instruction)
        XCTAssertEqual(
            ServicePermission.notGranted("Contacts", pane: "Full Disk Access").message,
            "Contacts access is not granted. \(instruction)"
        )
        for text in [
            ServicePermission.fullDiskAccess(hasPicker: true).settingsDetail,
            NotificationFetchError.accessDenied.errorDescription,
            BookmarkedSQLiteStore.AccessError.noBookmarkFound(picking: "the Messages database file").errorDescription,
            BrowserHistoryService.unreadable.message,
        ] {
            XCTAssertTrue(text?.contains(instruction) == true, text ?? "nil")
        }
    }
}
