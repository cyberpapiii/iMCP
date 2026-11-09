import Combine
import Foundation
import OSLog

/// Asks the person at the Mac about each client that wants in. One request is
/// on the window at a time and the rest wait their turn in arrival order, so
/// a second client cannot replace the window a user is reading; a request
/// left unanswered for `timeout` is declined. Every request handed to
/// `present` is answered exactly once, including one whose asking task is
/// cancelled because its connection went away.
@MainActor
final class ConnectionApprovalPresenter {
    private enum DeclineReason {
        /// Its connection went away.
        case withdrawn
        /// It sat on the window until its deadline.
        case timedOut
    }

    private let window: ConnectionApprovalWindowController
    private let timeout: Duration
    private let clock: WallClock
    private var active: ConnectionApprovalRequest?
    /// The requests waiting behind it, oldest first.
    private var queued: [ConnectionApprovalRequest] = []
    private var answers: [UUID: CheckedContinuation<ApprovalAnswer, Never>] = [:]
    private var timeoutTask: Task<Void, Never>?
    /// The key of the client last approved with pairing, while the window
    /// waits to hear whether it is now paired.
    private var awaitingPairing: String?
    private var outcomes: AnyCancellable?

    init(
        window: ConnectionApprovalWindowController,
        timeout: Duration,
        clock: WallClock,
        pairingOutcomes: AnyPublisher<PairingOutcome, Never>
    ) {
        self.window = window
        self.timeout = timeout
        self.clock = clock
        outcomes = pairingOutcomes.sink { [weak self] outcome in
            self?.pairingSettled(outcome)
        }
    }

    /// The answer: the person's, `.denied` once the request times out, or
    /// `.denied` as soon as the calling task is cancelled.
    func present(_ request: ConnectionApprovalRequest) async -> ApprovalAnswer {
        let connectionID = request.connectionID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .denied)
                    return
                }
                answers[connectionID] = continuation
                Logger.server.notice("Connection approval requested for client: \(request.clientName)")
                if active == nil {
                    active = request
                    show(request)
                } else {
                    queued.append(request)
                    window.updateWaiting(queued.count)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.decline(connectionID, .withdrawn)
            }
        }
    }

    /// Declines a request nobody will answer.
    private func decline(_ connectionID: UUID, _ reason: DeclineReason) {
        if active?.connectionID == connectionID {
            Logger.server.debug("Dismissing approval prompt for connection: \(connectionID)")
            stopTimeout()
            active = queued.isEmpty ? nil : queued.removeFirst()
            if let promoted = active {
                window.retireActiveRequest()
                show(promoted)
            } else if reason == .timedOut {
                window.showTimedOut()
            } else {
                window.dismissActiveApproval()
            }
        } else if let index = queued.firstIndex(where: { $0.connectionID == connectionID }) {
            Logger.server.debug("Dropping queued approval for removed connection: \(connectionID)")
            queued.remove(at: index)
            window.updateWaiting(queued.count)
        }
        answer(connectionID, .denied)
    }

    private func show(_ request: ConnectionApprovalRequest) {
        awaitingPairing = nil
        let deadline = startTimeout(for: request.connectionID)

        // Defer presentation by one turn. This method is reachable from inside
        // the previous window's button and close handlers, and showing a new
        // window on the same controller while those are still on the stack
        // lets their cleanup tear it right back down.
        Task { @MainActor [weak self] in
            guard let self, self.active?.connectionID == request.connectionID else { return }
            self.window.showApprovalWindow(
                ConnectionApprovalPrompt(request: request, deadline: deadline),
                waiting: self.queued.count,
                onApprove: { [weak self] pair in
                    self?.finish(request, approved: true, pair: pair)
                },
                onDeny: { [weak self] in
                    self?.finish(request, approved: false, pair: false)
                }
            )
        }
    }

    private func finish(_ request: ConnectionApprovalRequest, approved: Bool, pair: Bool) {
        // A window can be answered after its connection went away and
        // another request took its place; that late answer is not the new one's.
        guard active?.connectionID == request.connectionID else {
            Logger.server.error("Ignoring approval callback for inactive connection: \(request.connectionID)")
            closeWindowIfIdle()
            return
        }
        active = nil
        if approved {
            let pairs = pair && request.verifiedFingerprint != nil
            answer(request.connectionID, .approved(pair: pairs))
            if pairs { awaitingPairing = request.verifiedFingerprint }
        } else {
            answer(request.connectionID, .denied)
        }

        stopTimeout()
        if !queued.isEmpty {
            let next = queued.removeFirst()
            active = next
            show(next)
        }
        // The window stays to say "Paired" once the store has the client.
        if awaitingPairing == nil {
            closeWindowIfIdle()
        }
    }

    private func pairingSettled(_ outcome: PairingOutcome) {
        guard let fingerprint = awaitingPairing, outcome.fingerprint == fingerprint else { return }
        awaitingPairing = nil
        guard active == nil else { return }
        if outcome.client != nil {
            window.showPaired()
        } else {
            window.dismissActiveApproval()
        }
    }

    private func answer(_ connectionID: UUID, _ answer: ApprovalAnswer) {
        answers.removeValue(forKey: connectionID)?.resume(returning: answer)
    }

    /// Starts the clock on the request now on the window and returns when it runs out.
    private func startTimeout(for connectionID: UUID) -> Date {
        timeoutTask?.cancel()
        let timeout = timeout
        let clock = clock
        let deadline = clock.date(after: timeout)
        timeoutTask = Task { @MainActor [weak self] in
            // A cancelled sleep means the request was answered or superseded.
            guard (try? await clock.sleepUntil(deadline)) != nil else { return }
            guard let self, self.active?.connectionID == connectionID else { return }
            Logger.server.notice(
                "Approval prompt unanswered after \(timeout), denying connection: \(connectionID)"
            )
            self.decline(connectionID, .timedOut)
        }
        return deadline
    }

    private func stopTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    /// The window outlives each answer so the next request can take its place.
    /// With nothing left to ask, it goes.
    private func closeWindowIfIdle() {
        if active == nil {
            window.dismissActiveApproval()
        }
    }
}
