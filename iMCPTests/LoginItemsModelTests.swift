import AppKit
import ServiceManagement
import XCTest

@testable import iMCP

/// Settings' login-item switches, against a stand-in for ServiceManagement:
/// nothing here registers anything with the real system.
@MainActor
final class LoginItemsModelTests: XCTestCase {
    private final class FakeSystem {
        var mainApp: SMAppService.Status = .notRegistered
        var agent: SMAppService.Status = .notRegistered
        var mainAppCalls: [Bool] = []
        var alwaysOnCalls: [Bool] = []
        var failure: Error?

        var system: LoginItemsModel.System {
            LoginItemsModel.System(
                mainAppStatus: { self.mainApp },
                agentStatus: { self.agent },
                setMainAppRegistered: { register in
                    self.mainAppCalls.append(register)
                    if let failure = self.failure { throw failure }
                    self.mainApp = register ? .enabled : .notRegistered
                },
                setAlwaysOn: { enabled in
                    self.alwaysOnCalls.append(enabled)
                    if let failure = self.failure { throw failure }
                    self.agent = enabled ? .enabled : .notRegistered
                }
            )
        }
    }

    private struct Refused: LocalizedError {
        var errorDescription: String? { "Operation not permitted" }
    }

    /// The agent starts the app at login too, so with it on Launch at Login
    /// reads as on whatever the app's own login item says.
    func testAlwaysOnReadsAsLaunchingAtLogin() {
        let fake = FakeSystem()
        fake.agent = .enabled
        XCTAssertTrue(LoginItemsModel(system: fake.system).launchAtLogin)
        fake.agent = .notRegistered
        XCTAssertFalse(LoginItemsModel(system: fake.system).launchAtLogin)
    }

    /// The owner approves or revokes in System Settings and comes back; the
    /// switches show the system's answer as soon as the app is in front.
    func testComingToTheFrontReadsTheSystemAgain() {
        let fake = FakeSystem()
        let model = LoginItemsModel(system: fake.system)
        XCTAssertFalse(model.launchAtLogin)

        fake.mainApp = .enabled
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(model.launchAtLogin)
    }

    func testReadsWhatTheSystemSaysAtStart() {
        let fake = FakeSystem()
        fake.mainApp = .enabled
        let model = LoginItemsModel(system: fake.system)
        XCTAssertTrue(model.launchAtLogin)
        XCTAssertFalse(model.alwaysOn)
        XCTAssertFalse(model.approvalNeeded)
    }

    func testSwitchingLaunchAtLoginRegistersOnceAndShowsTheResult() {
        let fake = FakeSystem()
        let model = LoginItemsModel(system: fake.system)
        model.launchAtLogin = true
        XCTAssertEqual(fake.mainAppCalls, [true])
        XCTAssertTrue(model.launchAtLogin)

        model.launchAtLogin = false
        XCTAssertEqual(fake.mainAppCalls, [true, false])
        XCTAssertFalse(model.launchAtLogin)
    }

    func testAFailedRegistrationIsReportedAndTheSwitchShowsTheSystem() {
        let fake = FakeSystem()
        fake.failure = Refused()
        let model = LoginItemsModel(system: fake.system)
        model.launchAtLogin = true
        XCTAssertFalse(model.launchAtLogin)
        XCTAssertEqual(model.error, "Operation not permitted")

        fake.failure = nil
        model.launchAtLogin = true
        XCTAssertNil(model.error)
        XCTAssertTrue(model.launchAtLogin)
    }

    func testSwitchingAlwaysOnRegistersOnceAndShowsTheResult() {
        let fake = FakeSystem()
        let model = LoginItemsModel(system: fake.system)
        model.alwaysOn = true
        XCTAssertEqual(fake.alwaysOnCalls, [true])
        XCTAssertTrue(model.alwaysOn)
    }

    func testAnAgentAwaitingApprovalIsOnAndAsksForApproval() {
        let fake = FakeSystem()
        fake.agent = .requiresApproval
        let model = LoginItemsModel(system: fake.system)
        XCTAssertTrue(model.alwaysOn)
        XCTAssertTrue(model.approvalNeeded)

        fake.agent = .enabled
        model.refresh()
        XCTAssertFalse(model.approvalNeeded)
    }
}
