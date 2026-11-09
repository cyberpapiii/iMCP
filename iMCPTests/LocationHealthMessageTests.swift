import XCTest

@testable import iMCP

/// Seen live on 2026-09-28: Find My answered every ten minutes for hours while
/// the phone was in airplane mode, and `location_now` reported "expected every
/// 10" as though recording had broken.
final class LocationHealthMessageTests: XCTestCase {
    private let now = Date()

    private func health(
        sampler: LocationSamplerStatus,
        lastSampleAgeMinutes age: Double?,
        iCloud: LocationHealth.ICloud = .signedIn,
        hasLiveClient: Bool? = nil
    ) -> LocationHealth {
        LocationHealth(
            iCloud: iCloud,
            hasLiveClient: hasLiveClient ?? (iCloud == .signedIn),
            sampler: sampler,
            latestFixAt: age.map { now.addingTimeInterval(-$0 * 60) },
            now: now
        )
    }

    func testASilentPhoneIsNotReportedAsARecordingFault() throws {
        let message = try XCTUnwrap(
            health(
                sampler: LocationSamplerStatus(isRunning: true, lastSuccessAt: now.addingTimeInterval(-120)),
                lastSampleAgeMinutes: 271
            ).message
        )
        XCTAssertTrue(message.contains("Find My answered 2 minutes ago"), message)
        XCTAssertTrue(message.contains("271 minutes"), message)
        XCTAssertTrue(message.contains("Recording is working"), message)
    }

    func testAFailingSamplerStillSaysRecordingIsBehind() throws {
        let message = try XCTUnwrap(
            health(
                sampler: LocationSamplerStatus(
                    isRunning: true,
                    lastSuccessAt: now.addingTimeInterval(-7_200),
                    lastFailure: "The Internet connection appears to be offline."
                ),
                lastSampleAgeMinutes: 120
            ).message
        )
        XCTAssertTrue(message.contains("expected every 10"), message)
        XCTAssertTrue(message.contains("offline"), message)
    }

    func testARecentSampleNeedsNoMessage() {
        XCTAssertNil(
            health(sampler: LocationSamplerStatus(isRunning: true, lastSuccessAt: now), lastSampleAgeMinutes: 5)
                .message
        )
    }

    /// The tools' message and the window's flag read one overdue rule, the
    /// gap `VisitInference` calls a hole in the record.
    func testTheToolsAndTheWindowShareOneOverdueRule() {
        let running = LocationSamplerStatus(isRunning: true, lastSuccessAt: now.addingTimeInterval(-7_200))
        let gapMinutes = VisitInference.Rules().maximumGap / 60
        let onTime = health(sampler: running, lastSampleAgeMinutes: gapMinutes)
        let late = health(sampler: running, lastSampleAgeMinutes: gapMinutes + 1)
        XCTAssertNil(onTime.message)
        XCTAssertFalse(onTime.recordingNeedsAttention)
        XCTAssertNotNil(late.message)
        XCTAssertTrue(late.recordingNeedsAttention)
        XCTAssertTrue(health(sampler: running, lastSampleAgeMinutes: nil).recordingNeedsAttention)
        XCTAssertTrue(
            health(sampler: LocationSamplerStatus(isRunning: false), lastSampleAgeMinutes: 1).recordingNeedsAttention
        )
    }

    /// The `iCloud` field's values are wire output.
    func testICloudNamesAreTheToolsWireValues() {
        let names: [(ICloudSession.State, String)] = [
            (.signedIn(accountName: "a@b.c"), "signedIn"),
            (.working, "renewing"),
            (.reconnecting, "renewing"),
            (.needsReauthentication, "signInRequired"),
            (.credentialsUnreadable, "keychainUnreadable"),
            (.signedOut, "signedOut"),
        ]
        for (state, name) in names {
            XCTAssertEqual(LocationHealth.ICloud(state).rawValue, name)
        }
        XCTAssertEqual(LocationHealth.ICloud.codeNeeded.rawValue, "codeNeeded")
        let signedOut = health(
            sampler: LocationSamplerStatus(isRunning: true),
            lastSampleAgeMinutes: 1,
            iCloud: .signedOut
        )
        XCTAssertTrue(signedOut.message?.contains("(signedOut)") ?? false)
    }

    /// A silent renewal keeps the live client, and the tools keep answering
    /// on it, so their health line must not say recording stopped.
    func testARenewalWithALiveClientIsNotReportedAsPaused() {
        let running = LocationSamplerStatus(isRunning: true, lastSuccessAt: now)
        XCTAssertNil(health(sampler: running, lastSampleAgeMinutes: 5, iCloud: .renewing, hasLiveClient: true).message)

        let reconnecting = health(sampler: running, lastSampleAgeMinutes: 5, iCloud: .renewing, hasLiveClient: false)
        let message = reconnecting.message ?? ""
        XCTAssertTrue(message.contains("recording is paused"), message)
        XCTAssertFalse(message.contains("sign in"), "a queued retry needs nobody: \(message)")
    }
}
