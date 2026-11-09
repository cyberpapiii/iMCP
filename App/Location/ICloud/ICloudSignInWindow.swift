import AppKit
import SwiftUI

@MainActor
final class ICloudSignInWindowController: NSWindowController, NSWindowDelegate {
    private var didClose: (ICloudSignInWindowController) -> Void = { _ in }

    convenience init(session: ICloudSession, didClose: @escaping (ICloudSignInWindowController) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: DesignTokens.Size.promptWidth, height: 0),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to iCloud"
        let content = NSHostingView(
            rootView: ICloudSignInView(session: session, close: { [weak window] in window?.close() })
        )
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
        self.didClose = didClose
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        // Dropped on the next turn, not inside the window's own close.
        Task { [self] in didClose(self) }
    }
}

/// Shows the sign-in window from anywhere, and lets go of it when it
/// closes: the view holds whatever was typed, and a closed window must
/// not keep a password or a code alive.
///
/// The menu opens it, and so does the warning badge on the Location service —
/// the same window either way, because there is only ever one sign-in.
@MainActor
final class ICloudSignInPresenter {
    private var window: SingleWindowPresenter<ICloudSignInWindowController>?

    init(session: ICloudSession, activation: WindowActivation) {
        window = SingleWindowPresenter(activation: activation) { [weak self] in
            ICloudSignInWindowController(session: session) { closed in self?.window?.release(closed) }
        }
    }

    func show() {
        window?.show()
    }
}

/// What the sign-in window says for each step. A step in progress keeps the
/// step it came from on show, so only the button says that work is going on.
enum ICloudSignInScreen {
    /// A step the window shows: every session state except `working`.
    enum Step: Equatable {
        case signedOut
        case needsReauthentication
        case reconnecting
        case awaitingCode(ICloudTwoFactorDelivery)
        case signedIn(accountName: String)
        case credentialsUnreadable

        init?(_ state: ICloudSession.State) {
            switch state {
            case .working: return nil
            case .signedOut: self = .signedOut
            case .needsReauthentication: self = .needsReauthentication
            case .reconnecting: self = .reconnecting
            case .awaitingCode(let delivery): self = .awaitingCode(delivery)
            case .signedIn(let accountName): self = .signedIn(accountName: accountName)
            case .credentialsUnreadable: self = .credentialsUnreadable
            }
        }
    }

    static func step(previous: Step, current: ICloudSession.State) -> Step {
        Step(current) ?? previous
    }

    /// The same words as the status row, except that a window which is
    /// itself the sign-in form says so when nobody is signed in, and has room
    /// to put the keychain fix underneath.
    static func title(for step: Step) -> String {
        switch step {
        case .awaitingCode: return ICloudStatus.awaitingCode
        case .signedIn: return "Signed in to iCloud"
        case .credentialsUnreadable: return ICloudStatus.unreadable
        case .reconnecting: return "Reconnecting to iCloud"
        case .signedOut, .needsReauthentication: return ICloudStatus.signIn
        }
    }

    static func explanation(for step: Step) -> String {
        switch step {
        case .awaitingCode(.trustedDevice):
            return "Enter the six-digit code shown on your other Apple devices."
        case .awaitingCode(.sms(let number, _)):
            return "Enter the six-digit code sent to \(number)."
        case .signedIn:
            return "Location tools can now see where your people and devices are."
        case .needsReauthentication:
            return
                "The saved iCloud session expired. Signing in again restores the Location tools."
        case .reconnecting:
            return
                "iMCP could not reach iCloud to restore the saved session and is trying again by itself. "
                + "There is nothing to do unless it keeps failing."
        case .credentialsUnreadable:
            return
                "\(ICloudStatus.unlockKeychain), then try again. "
                + "Signing in now would overwrite a sign-in that is still saved."
        case .signedOut:
            return
                "iMCP uses your iCloud account to find your devices and the people sharing "
                + "location with you. Your password stays in the Keychain on this Mac so iMCP can "
                + "sign in again by itself when the session expires."
        }
    }

    /// What the main button does.
    private enum PrimaryAction: CaseIterable {
        case signIn
        case verify
        case tryAgain
        case done

        var words: (idle: String, working: String) {
            switch self {
            case .signIn: return ("Sign In", "Signing In…")
            case .verify: return ("Verify", "Verifying…")
            case .tryAgain: return ("Try Again", "Checking…")
            case .done: return ("Done", "Done")
            }
        }
    }

    private static func primaryAction(for step: Step) -> PrimaryAction {
        switch step {
        case .awaitingCode: return .verify
        case .signedIn: return .done
        case .credentialsUnreadable: return .tryAgain
        case .signedOut, .needsReauthentication, .reconnecting: return .signIn
        }
    }

    static func primary(for step: Step) -> (idle: String, working: String) {
        primaryAction(for: step).words
    }

    /// Every face the main button can wear, so it is as wide as the widest.
    static let primaryFaces: [SteadyLabel.Face] = PrimaryAction.allCases.flatMap { action in
        let words = action.words
        let idle = SteadyLabel.Face(text: words.idle)
        return words.working == words.idle ? [idle] : [idle, SteadyLabel.Face(text: words.working, working: true)]
    }

    /// The failure, followed by what to do about it when the failure itself
    /// does not say.
    static func failureText(_ failure: ICloudFailure) -> String {
        let message = failure.message
        switch failure {
        case .auth(.invalidCredentials):
            return "\(message) What you typed is still here: check both and try again."
        case .auth(.twoFactorCodeRejected):
            return "\(message) Check the code and try again, or start over to get a new one."
        case .auth(.unreadableResponse), .auth(.appleRejectedRequest):
            return "\(message) Try again in a few minutes."
        default:
            return message
        }
    }
}

/// The only place the user's Apple ID password is ever typed. It lives in this
/// view's `@State` until Apple accepts it, so a failed attempt can be corrected
/// instead of retyped, and the view itself goes when the window closes. Nothing
/// typed here is logged or stored by the view.
private struct ICloudSignInView: View {
    private enum Field {
        case accountName
        case password
        case code
    }

    @ObservedObject var session: ICloudSession
    let close: () -> Void

    @State private var accountName = ""
    @State private var password = ""
    @State private var code = ""
    /// The step on show. Stays put while the session is only working.
    @State private var shown: ICloudSignInScreen.Step
    /// True from the moment a form is submitted until the session has taken it.
    @State private var submitting = false
    @FocusState private var focus: Field?

    init(session: ICloudSession, close: @escaping () -> Void) {
        self.session = session
        self.close = close
        _shown = State(initialValue: ICloudSignInScreen.step(previous: .signedOut, current: session.state))
    }

    private var working: Bool { submitting || session.state == .working }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            FittedHeight {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    Text(ICloudSignInScreen.title(for: shown))
                        .font(DesignTokens.Typography.sheetTitle)
                        .contentTransition(.opacity)

                    Text(ICloudSignInScreen.explanation(for: shown))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)

                    fields
                        .disabled(working)

                    if let failure = session.lastFailure {
                        StatusNote(level: .problem, text: ICloudSignInScreen.failureText(failure))
                            .transition(.reveal())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .motion(.surface, value: shown)
                .motion(.surface, value: session.lastFailure)
            }

            buttons
        }
        .padding(DesignTokens.Spacing.window)
        .frame(width: DesignTokens.Size.promptWidth)
        .onAppear {
            if case .awaitingCode = shown { focus = .code } else { focus = .accountName }
        }
        .onChange(of: session.state) { _, state in
            shown = ICloudSignInScreen.step(previous: shown, current: state)
        }
        .onChange(of: shown) { _, shown in
            // Apple took the password, or the code: neither is needed again.
            switch shown {
            case .awaitingCode:
                password = ""
                focus = .code
            case .signedIn:
                password = ""
                code = ""
            case .signedOut, .needsReauthentication, .reconnecting, .credentialsUnreadable:
                // Back at the start: the code belonged to an attempt that is over.
                code = ""
            }
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch shown {
        case .awaitingCode:
            TextField("Verification Code", text: $code)
                .textContentType(.oneTimeCode)
                .focused($focus, equals: .code)
                .onSubmit(submit)
                .transition(.reveal())
        case .signedIn(let signedInAs):
            Text(signedInAs)
                .font(.callout)
                .textSelection(.enabled)
                .transition(.reveal())
        case .credentialsUnreadable:
            EmptyView()
        case .signedOut, .needsReauthentication, .reconnecting:
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                TextField("Apple ID", text: $accountName)
                    .textContentType(.username)
                    .focused($focus, equals: .accountName)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .onSubmit(submit)
            }
            .transition(.reveal())
        }
    }

    /// Cancel and the main button keep their places from step to step: the
    /// main button is always as wide as its widest wording.
    private var buttons: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            switch shown {
            case .needsReauthentication, .reconnecting:
                Button("Sign Out") {
                    Task { await session.signOut() }
                }
                .disabled(working)
            case .awaitingCode:
                Button("Start Over") {
                    code = ""
                    session.beginManualSignIn()
                }
                .disabled(working)
            case .signedIn:
                ICloudSignOutButton(session: session)
            case .signedOut, .credentialsUnreadable:
                EmptyView()
            }

            Spacer()

            Button("Cancel", action: close)
                .keyboardShortcut(.cancelAction)
                .opacity(isDone ? 0 : 1)
                .disabled(isDone)
                .accessibilityHidden(isDone)

            Button(action: submit) {
                SteadyLabel(faces: ICloudSignInScreen.primaryFaces, current: primaryFace)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(working || !canSubmit)
        }
        .motion(.quick, value: shown)
    }

    private var isDone: Bool {
        if case .signedIn = shown { return true }
        return false
    }

    private var primaryFace: SteadyLabel.Face {
        let words = ICloudSignInScreen.primary(for: shown)
        return working ? .init(text: words.working, working: true) : .init(text: words.idle)
    }

    /// A pasted code arrives as "123 456" or "123-456". Apple wants the
    /// six digits.
    private var codeDigits: String { code.filter { ("0" ... "9").contains($0) } }

    private var canSubmit: Bool {
        switch shown {
        case .awaitingCode: return codeDigits.count == 6
        case .signedIn, .credentialsUnreadable: return true
        case .signedOut, .needsReauthentication, .reconnecting: return !typedAccountName.isEmpty && !password.isEmpty
        }
    }

    /// Autofill and paste can bring a space or a newline with the Apple ID,
    /// and Apple looks the name up exactly as sent.
    private var typedAccountName: String { accountName.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Return in a field and the main button both land here; a form already
    /// handed over is not sent twice.
    private func submit() {
        guard !working, canSubmit else { return }
        switch shown {
        case .signedIn:
            close()
        case .credentialsUnreadable:
            hand { await session.retryKeychain() }
        case .awaitingCode:
            let digits = codeDigits
            hand { await session.submitTwoFactorCode(digits) }
        case .signedOut, .needsReauthentication, .reconnecting:
            let name = typedAccountName
            let secret = password
            hand { await session.signIn(accountName: name, password: secret) }
        }
    }

    private func hand(_ attempt: @escaping @MainActor () async -> Void) {
        submitting = true
        Task {
            await attempt()
            submitting = false
        }
    }
}

/// Signing out throws the stored session away, and getting it back costs the
/// password and a verification code. Both Sign Out buttons for a signed-in
/// session are this one.
struct ICloudSignOutButton: View {
    let session: ICloudSession
    @State private var confirming = false

    var body: some View {
        Button("Sign Out…") { confirming = true }
            .confirmationDialog("Sign out of iCloud?", isPresented: $confirming) {
                Button("Sign Out", role: .destructive) {
                    Task { await session.signOut() }
                }
            } message: {
                Text(
                    "Location stops working until you sign in again with your Apple ID password and a verification code."
                )
            }
    }
}
