import Foundation

/// Whether Location is recording, worked out once for the tools and the
/// window. Pure: everything it reads is an argument.
struct LocationHealth: Equatable, Sendable {
    /// The session state as the tools' `iCloud` field spells it. These raw
    /// values are wire output; do not rename them.
    enum ICloud: String, Equatable, Sendable {
        case signedIn
        case renewing
        case codeNeeded
        case signInRequired
        case keychainUnreadable
        case signedOut

        init(_ state: ICloudSession.State) {
            switch state {
            case .signedIn: self = .signedIn
            // A queued restore retry renews by itself, as a renewal does.
            case .working, .reconnecting: self = .renewing
            case .awaitingCode: self = .codeNeeded
            case .needsReauthentication: self = .signInRequired
            case .credentialsUnreadable: self = .keychainUnreadable
            case .signedOut: self = .signedOut
            }
        }
    }

    var iCloud: ICloud
    /// Whether Find My can be called now. A renewal keeps the old client, so
    /// this stays true while `iCloud` says `renewing`.
    var hasLiveClient: Bool
    var sampler: LocationSamplerStatus
    /// The newest device fix recorded, Find My People rows excluded.
    var latestFixAt: Date?
    var now: Date

    init(iCloud: ICloud, hasLiveClient: Bool, sampler: LocationSamplerStatus, latestFixAt: Date?, now: Date) {
        self.iCloud = iCloud
        self.hasLiveClient = hasLiveClient
        self.sampler = sampler
        self.latestFixAt = latestFixAt
        self.now = now
    }

    /// What the tools and the window both judge recording by.
    @MainActor
    init(session: ICloudSession, sampler: LocationSamplerStatus, latestFixAt: Date?, now: Date) {
        self.init(
            iCloud: ICloud(session.state),
            hasLiveClient: session.hasLiveClient,
            sampler: sampler,
            latestFixAt: latestFixAt,
            now: now
        )
    }

    var lastSampleAgeMinutes: Int? {
        latestFixAt.map { Int(now.timeIntervalSince($0) / 60) }
    }

    /// The record is further behind than the gap `VisitInference` calls a
    /// hole, counted in whole minutes as every report states it.
    var isRecordingOverdue: Bool {
        guard let age = lastSampleAgeMinutes else { return false }
        return age > Int(LocationPolicy.recordingOverdue / 60)
    }

    /// Whether the window flags recording: off, never recorded, or overdue.
    /// A phone that went quiet still leaves a hole in the record, so this
    /// does not make the exception `message` makes for one.
    var recordingNeedsAttention: Bool {
        !sampler.isRunning || latestFixAt == nil || isRecordingOverdue
    }

    var recordingText: String {
        sampler.isRunning ? "Recording every \(LocationPolicy.expectedIntervalMinutes) min" : "Not recording"
    }

    /// One sentence a person can act on, or nil when recording is healthy.
    var message: String? {
        let interval = LocationPolicy.expectedIntervalMinutes
        if !hasLiveClient, iCloud == .renewing {
            return
                "iCloud is reconnecting (\(iCloud.rawValue)); recording is paused and live positions are unavailable "
                + "until it does. iMCP retries by itself."
        }
        if !hasLiveClient {
            return
                "iCloud is not signed in (\(iCloud.rawValue)); recording is paused and live positions are unavailable. "
                + "Open the iMCP menu to sign in."
        }
        if !sampler.isRunning {
            return "Recording is off; turn Location on in iMCP to record positions."
        }
        guard isRecordingOverdue, let age = lastSampleAgeMinutes else { return nil }
        // The sampler only records a fix newer than the last one. When Find My
        // keeps answering but the phone reports nothing new, the hole is the
        // phone's (off, airplane mode, no signal), not a recording fault.
        if sampler.lastFailure == nil, let success = sampler.lastSuccessAt,
            now.timeIntervalSince(success) <= LocationPolicy.sampleInterval * 2
        {
            let polled = max(0, Int(now.timeIntervalSince(success) / 60))
            return "Find My answered \(polled) minutes ago, but the phone has reported no new position for "
                + "\(age) minutes; it may be off, in airplane mode, or without signal. Recording is working."
        }
        return "The last position was recorded \(age) minutes ago; expected every \(interval)."
            + (sampler.lastFailure.map { " Last failure: \($0)" } ?? "")
    }
}
