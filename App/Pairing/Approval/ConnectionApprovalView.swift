import AppKit
import SwiftUI

/// One request to connect, as the approval window shows it.
struct ConnectionApprovalPrompt: Equatable {
    enum Phase: Equatable {
        case asking
        /// Answered. The window waits for what follows: the next request,
        /// or word that the client it was told to pair is paired.
        case answered
        /// Nobody answered in time. The request is already declined.
        case timedOut
        /// Approved and paired for the first time, with nothing waiting behind it.
        case paired
    }

    let request: ConnectionApprovalRequest
    /// When the request is declined if nobody answers.
    let deadline: Date
    /// Where this request stands among those the window has shown since it opened.
    var position = 1
    var total = 1
    var phase = Phase.asking

    var countText: String? {
        total > 1 ? "\(position) of \(total)" : nil
    }

    func notice(at now: Date) -> String {
        switch phase {
        case .timedOut:
            return "Declined, no answer."
        case .paired:
            return "Paired."
        case .asking, .answered:
            return "Declines automatically in \(Self.remainingText(deadline.timeIntervalSince(now)))."
        }
    }

    /// Time left in round words. Nothing here changes more often than every
    /// ten seconds, so the notice never needs a ticking clock.
    static func remainingText(_ seconds: TimeInterval) -> String {
        if seconds > 90 { return "about \(Int((seconds / 60).rounded())) minutes" }
        if seconds > 50 { return "about a minute" }
        return "about \(max(1, Int((seconds / 10).rounded(.up))) * 10) seconds"
    }

    /// How long until `notice(at:)` could read differently.
    static func nextNoticeChange(after remaining: TimeInterval) -> TimeInterval {
        let step = remaining.truncatingRemainder(dividingBy: 10)
        return step < 1 ? step + 10 : step
    }
}

/// What the approval window is showing now. The window and this model stay
/// for the life of the app; requests pass through them.
@MainActor
final class ConnectionApprovalPromptModel: ObservableObject {
    @Published var prompt: ConnectionApprovalPrompt?
    /// Asked afresh for every request: pairing one client says nothing about the next.
    @Published var pairOnApprove = false
    /// Counts the times the window has opened, so each opening starts at its own size.
    @Published var opening = 0
}

struct ConnectionApprovalView: View {
    @ObservedObject var model: ConnectionApprovalPromptModel
    let onApprove: (_ pairClient: Bool) -> Void
    let onDeny: () -> Void

    @State private var now = Date()

    private static let approve = SteadyLabel.Face(text: "Approve")
    private static let approveAndPair = SteadyLabel.Face(text: "Approve and Pair")

    var body: some View {
        let prompt = model.prompt
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            FittedHeight {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                    HStack(alignment: .top) {
                        Image(.menuIconOn)
                            .resizable()
                            .foregroundStyle(Color.accentColor)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: DesignTokens.Size.promptIcon, height: DesignTokens.Size.promptIcon)
                            .accessibilityHidden(true)
                        Spacer()
                        if let count = prompt?.countText {
                            Text(count)
                                .font(DesignTokens.Typography.detail)
                                .foregroundStyle(.secondary)
                                .contentTransition(.opacity)
                                .accessibilityLabel("Request \(count)")
                                .transition(.opacity)
                        }
                    }

                    Text("Connection Request")
                        .font(.title2)
                        .fontWeight(.semibold)

                    if let prompt {
                        details(prompt)
                            .id(prompt.request.connectionID)
                            .transition(.reveal())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .motion(.surface, value: prompt?.request.connectionID)
                .motion(.quick, value: prompt?.countText)
            }

            HStack(spacing: DesignTokens.Spacing.md) {
                Spacer()
                // Escape and the close button decline. Return does nothing: a
                // stray keystroke must never let a client in.
                Button("Deny", action: onDeny)
                    .keyboardShortcut(.cancelAction)
                Button {
                    onApprove(model.pairOnApprove)
                } label: {
                    SteadyLabel(
                        faces: [Self.approve, Self.approveAndPair],
                        current: model.pairOnApprove ? Self.approveAndPair : Self.approve
                    )
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(prompt?.phase != .asking)
        }
        .padding(DesignTokens.Spacing.window)
        .frame(width: DesignTokens.Size.promptWidth)
        .id(model.opening)
        .task(id: prompt?.request.connectionID) {
            await keepTime()
        }
    }

    private func details(_ prompt: ConnectionApprovalPrompt) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("Allow \"\(prompt.request.clientName)\" to connect to iMCP?")
                .fixedSize(horizontal: false, vertical: true)

            if let fingerprint = prompt.request.verifiedFingerprint {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                    Text("Verified key:")
                        .font(DesignTokens.Typography.detail)
                    Text(PairedClient.shortFingerprint(fingerprint))
                        .font(DesignTokens.Typography.code)
                        .textSelection(.enabled)
                }
                .foregroundStyle(.secondary)
            }

            Text("The client can use every service you have enabled.")
                .font(DesignTokens.Typography.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if prompt.request.verifiedFingerprint != nil {
                Toggle("Always allow this client (pair)", isOn: $model.pairOnApprove)
                    .font(DesignTokens.Typography.detail)
                    .disabled(prompt.phase != .asking)
            }

            Label {
                Text(prompt.notice(at: now))
                    .contentTransition(.opacity)
            } icon: {
                Image(systemName: prompt.phase == .timedOut ? "clock.badge.xmark" : "clock")
                    .opacity(prompt.phase == .paired ? 0 : 1)
                    .overlay {
                        SuccessTick(isDrawn: prompt.phase == .paired, announcement: "Client paired")
                            .foregroundStyle(DesignTokens.StatusColor.ok)
                    }
            }
            .font(DesignTokens.Typography.detail)
            .foregroundStyle(.secondary)
            .motion(.quick, value: prompt.notice(at: now))
        }
    }

    /// Rewords the notice as the deadline nears: once on show, then only when
    /// the words would change. Ends with the request, and with the window.
    private func keepTime() async {
        guard let deadline = model.prompt?.deadline else { return }
        while !Task.isCancelled {
            now = Date()
            let remaining = deadline.timeIntervalSince(now)
            guard remaining > 0 else { return }
            try? await Task.sleep(for: .seconds(ConnectionApprovalPrompt.nextNoticeChange(after: remaining)))
        }
    }
}

/// The one approval window. It opens for the first waiting request, shows each
/// later one in place, and closes when none is left.
@MainActor
final class ConnectionApprovalWindowController: NSObject, NSWindowDelegate {
    private struct Handlers {
        let approve: (_ pairClient: Bool) -> Void
        let deny: () -> Void
    }

    let model = ConnectionApprovalPromptModel()
    private let activation: WindowActivation
    private(set) var window: NSWindow?
    /// Set while a request is waiting for its answer. Cleared the moment it
    /// has one, so a button and the window's close cannot both answer.
    private var handlers: Handlers?
    /// Requests settled since the window opened, for "2 of 3".
    private var settled = 0
    private var closingNotice: Task<Void, Never>?
    private var isClosing = false

    var isOpen: Bool { window?.isVisible ?? false }

    init(activation: WindowActivation) {
        self.activation = activation
        super.init()
    }

    func showApprovalWindow(
        _ prompt: ConnectionApprovalPrompt,
        waiting: Int,
        onApprove: @escaping (_ pairClient: Bool) -> Void,
        onDeny: @escaping () -> Void
    ) {
        closingNotice?.cancel()
        closingNotice = nil
        let window = self.window ?? makeWindow()
        self.window = window
        let opening = !window.isVisible
        if opening {
            settled = 0
            model.opening += 1
        }

        var prompt = prompt
        prompt.position = settled + 1
        prompt.total = settled + 1 + waiting
        handlers = Handlers(approve: onApprove, deny: onDeny)
        model.pairOnApprove = false
        model.prompt = prompt

        if opening, let content = window.contentView {
            window.setContentSize(content.fittingSize)
            // AppKit's center() sits a window above the middle of the screen.
            if let screen = NSScreen.main?.visibleFrame {
                window.setFrameOrigin(
                    NSPoint(x: screen.midX - window.frame.width / 2, y: screen.midY - window.frame.height / 2)
                )
            }
        }

        activation.bringToFront(window)
    }

    func updateWaiting(_ waiting: Int) {
        guard let prompt = model.prompt else { return }
        model.prompt?.total = prompt.position + waiting
    }

    /// The request on show was settled elsewhere and another follows it: the
    /// window stays for the next one.
    func retireActiveRequest() {
        guard handlers != nil else { return }
        handlers = nil
        settled += 1
        model.prompt?.phase = .answered
    }

    /// The request on show ran out of time and none follows it: say so, then close.
    func showTimedOut() {
        close(saying: .timedOut, after: DesignTokens.Linger.closingNotice)
    }

    /// The request on show was approved and its client paired for the first
    /// time, and none follows it: say so, then close. The client is already in.
    func showPaired() {
        close(saying: .paired, after: DesignTokens.Linger.pairedNotice)
    }

    private func close(saying phase: ConnectionApprovalPrompt.Phase, after linger: Duration) {
        guard isOpen, let connectionID = model.prompt?.request.connectionID else {
            dismissActiveApproval()
            return
        }
        handlers = nil
        model.prompt?.phase = phase
        closingNotice?.cancel()
        closingNotice = Task { [weak self] in
            try? await Task.sleep(for: linger)
            guard !Task.isCancelled, let self, self.model.prompt?.request.connectionID == connectionID,
                self.model.prompt?.phase == phase
            else { return }
            self.dismissActiveApproval()
        }
    }

    /// Closes the window without answering. The presenter has already
    /// settled the request.
    func dismissActiveApproval() {
        handlers = nil
        closingNotice?.cancel()
        closingNotice = nil
        guard !isClosing else { return }
        window?.close()
    }

    /// Closing the window without answering (red titlebar button) counts as
    /// a denial; otherwise the approval continuation leaks and every later
    /// approval queues forever.
    func windowWillClose(_ notification: Notification) {
        let deny = handlers?.deny
        handlers = nil
        closingNotice?.cancel()
        closingNotice = nil
        model.prompt = nil
        settled = 0
        isClosing = true
        deny?()
        isClosing = false
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: DesignTokens.Size.promptWidth, height: 0),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Connection Request"
        window.contentView = NSHostingView(
            rootView: ConnectionApprovalView(
                model: model,
                onApprove: { [weak self] pairClient in self?.approve(pair: pairClient) },
                onDeny: { [weak self] in self?.deny() }
            )
        )
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.level = .floating
        return window
    }

    func approve(pair: Bool) {
        answer { $0.approve(pair) }
    }

    func deny() {
        answer { $0.deny() }
    }

    /// The window stays while the answer is delivered: whoever receives it
    /// either sends the next request here or closes the window.
    private func answer(_ deliver: (Handlers) -> Void) {
        guard let handlers else { return }
        self.handlers = nil
        settled += 1
        model.prompt?.phase = .answered
        deliver(handlers)
    }
}
