import AppKit
import Foundation
import OSLog
import WebKit

enum FindMyWebAuthorizationError: Swift.Error, ClientFacingError, Equatable {
    case credentialsRejected
    case timedOut
    case navigationFailed

    var errorDescription: String? {
        switch self {
        case .credentialsRejected:
            return
                "Apple rejected the saved password while authorizing Find My. Sign in to iMCP again with the current password."
        case .timedOut:
            return "Find My did not finish its private authorization. Open iMCP and sign in again."
        case .navigationFailed:
            return "Find My's private authorization page could not load."
        }
    }
}

/// What Apple's Find My page left behind: its Apple cookies, and the client id
/// it sent to iCloud. The page mints its own id, and Apple binds the session
/// the page signed in to that id, so replaying the cookies under another one
/// earns 421.
struct FindMyWebAuthorization: Sendable, Equatable {
    var cookies: [HTTPCookie]
    var clientID: String?
}

/// Apple's own Find My password page, run on the session's cookies. Find My
/// no longer accepts the setup service's direct password route.
protocol FindMyWebAuthorizing: Sendable {
    /// Signs in to Find My alone, starting from `cookies`, and returns what
    /// the page left behind, its `X-APPLE-WEBAUTH-FMIP` cookie among it.
    func authorize(accountName: String, password: String, cookies: [HTTPCookie]) async throws
        -> FindMyWebAuthorization
}

struct FindMyWebKitAuthorizer: FindMyWebAuthorizing {
    func authorize(accountName: String, password: String, cookies: [HTTPCookie]) async throws
        -> FindMyWebAuthorization
    {
        try await FindMyWebAuthorizer(accountName: accountName, password: password, cookies: cookies).authorize()
    }
}

/// Runs Apple's own `/find` page in an isolated, hidden WebKit session. The
/// page owns the one-factor challenge and sets `X-APPLE-WEBAUTH-FMIP` when done.
///
/// The page receives only the cookies already held by iMCP. Its result is
/// copied back into iMCP's isolated URLSession jar; WebKit persists nothing.
@MainActor
final class FindMyWebAuthorizer: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private static let log = Logger.service("location.findmy-authorization")
    private static let findURL = URL(string: "https://www.icloud.com/find")!
    /// The injected script and this class talk through one message handler.
    static let messageHandler = "imcpFindMyAuthorization"
    /// What the script posts when Apple's page refuses the password.
    static let credentialsRejectedMessage = "credentials rejected"
    /// How long to wait, once the service cookie is set, for the page's own
    /// Find My call before taking the cookies as they are.
    static let settleAfterServiceCookie: Duration = .seconds(8)

    private let accountName: String
    private let password: String
    private let initialCookies: [HTTPCookie]
    private let timeout: Duration

    private var continuation: CheckedContinuation<FindMyWebAuthorization, Swift.Error>?
    /// The client id on the page's last accepted iCloud call.
    private var pageClientID: String?
    /// Whether Find My answered the page itself, which is when its session
    /// is complete.
    private var pageFindMyAccepted = false
    private var hostWindow: NSPanel?
    private var webView: WKWebView?
    private var pollTask: Task<Void, Never>?

    init(
        accountName: String,
        password: String,
        cookies: [HTTPCookie],
        timeout: Duration = .seconds(40)
    ) {
        self.accountName = accountName
        self.password = password
        self.initialCookies = cookies
        self.timeout = timeout
    }

    func authorize() async throws -> FindMyWebAuthorization {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                Task { await self.start() }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func start() async {
        guard continuation != nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        controller.add(self, name: Self.messageHandler)
        controller.addUserScript(
            WKUserScript(
                source: Self.autofillScript(accountName: accountName, password: password),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        configuration.userContentController = controller

        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 800), configuration: configuration)
        view.customUserAgent = ICloudHTTPClient.userAgent
        view.navigationDelegate = self
        // WebKit throttles a view that is not on screen, and Apple's SRP
        // worker then stops after `signin/init`. A nearly transparent,
        // non-activating panel keeps it running without being seen.
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 800),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0.01
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView = view
        window.orderFrontRegardless()
        hostWindow = window
        webView = view

        let store = configuration.websiteDataStore.httpCookieStore
        // Only Apple's cookies go into the page and come back out of it.
        for cookie in initialCookies where AppleDomain.isSessionCookie(cookie) {
            await store.setCookie(cookie)
        }
        guard continuation != nil else { return }

        Self.log.notice("Starting isolated Find My web authorization")
        view.load(URLRequest(url: Self.findURL))
        // Polled rather than observed: WKHTTPCookieStoreObserver is unproven
        // for a non-persistent store on Apple's live page, and a missed change
        // would time out after the password went out.
        let timeout = timeout
        // The service cookie arrives before the page has finished: it still
        // makes its own Find My call, and cookies taken before that can name a
        // session Apple has not settled. So the cookies are taken once Find My
        // answers the page, or a few seconds after the cookie if it never does.
        pollTask = Task { [weak self] in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            var serviceCookieAt: ContinuousClock.Instant?
            while !Task.isCancelled {
                let expired = clock.now >= deadline
                if !expired {
                    guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
                }
                let cookies = await store.allCookies()
                guard let self else { return }
                if serviceCookieAt == nil, cookies.contains(where: { $0.name == ICloudCookie.findMyAuthorization }) {
                    Self.log.notice("Find My web authorization produced its service cookie")
                    serviceCookieAt = clock.now
                }
                if let serviceCookieAt,
                    self.pageFindMyAccepted || expired
                        || clock.now >= serviceCookieAt.advanced(by: Self.settleAfterServiceCookie)
                {
                    Self.log.notice(
                        "Find My page finished: its own Find My call \(self.pageFindMyAccepted ? "accepted" : "not seen", privacy: .public), client id \(self.pageClientID == nil ? "not seen" : "seen", privacy: .public)"
                    )
                    self.finish(
                        .success(
                            FindMyWebAuthorization(
                                cookies: cookies.filter(AppleDomain.isSessionCookie),
                                clientID: self.pageClientID
                            )
                        )
                    )
                    return
                }
                if expired { break }
            }
            self?.finish(.failure(FindMyWebAuthorizationError.timedOut))
        }
    }

    private func finish(_ result: Result<FindMyWebAuthorization, Swift.Error>) {
        guard let continuation else { return }
        self.continuation = nil
        pollTask?.cancel()
        pollTask = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandler)
        webView?.navigationDelegate = nil
        webView = nil
        hostWindow?.orderOut(nil)
        hostWindow?.close()
        hostWindow = nil
        continuation.resume(with: result)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(Self.isAllowedNavigation(url) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        let host = webView.url?.host ?? "none"
        let path = webView.url?.path ?? "none"
        Self.log.notice("Find My authorization loaded \(host, privacy: .public)\(path, privacy: .public)")
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let text = message.body as? String else { return }
        if let call = PageCall(text) {
            record(call)
            return
        }
        Self.log.notice("Find My authorization page: \(String(text.prefix(160)), privacy: .public)")
        if text == Self.credentialsRejectedMessage {
            finish(.failure(FindMyWebAuthorizationError.credentialsRejected))
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Swift.Error
    ) {
        Self.log.error(
            "Find My authorization navigation failed: \(String(describing: type(of: error)), privacy: .public)"
        )
        finish(.failure(FindMyWebAuthorizationError.navigationFailed))
    }

    /// One of the page's own calls to iCloud's setup or Find My service, as
    /// the script reports it: the path, Apple's status, and the client id the
    /// page sent. No body, cookie, or token.
    struct PageCall: Equatable {
        let path: String
        let status: Int
        let clientID: String?

        init?(_ message: String) {
            guard
                message.hasPrefix("{"),
                let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
                let path = object["request"] as? String,
                let status = object["status"] as? Int
            else { return nil }
            self.path = path
            self.status = status
            self.clientID = (object["clientId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }

        var accepted: Bool { (200 ..< 300).contains(status) }
        var isFindMy: Bool { path.contains("/fmipservice/") }
    }

    private func record(_ call: PageCall) {
        Self.log.notice(
            "Find My page call: \(call.path, privacy: .public) -> \(call.status, privacy: .public)"
        )
        guard call.accepted else { return }
        if let id = call.clientID { pageClientID = id }
        if call.isFindMy { pageFindMyAccepted = true }
    }

    private static func isAllowedNavigation(_ url: URL) -> Bool {
        if ["about", "data", "blob"].contains(url.scheme?.lowercased() ?? "") { return true }
        guard url.scheme?.lowercased() == "https", let host = url.host else { return false }
        return AppleDomain.contains(host, in: AppleDomain.account + AppleDomain.iCloud + AppleDomain.webContent)
    }

    private static func autofillScript(accountName: String, password: String) -> String {
        let account = jsonLiteral(accountName)
        let password = jsonLiteral(password)
        let rejected = jsonLiteral(credentialsRejectedMessage)
        return """
            (() => {
              const report = (message) => {
                try { window.webkit.messageHandlers.\(messageHandler).postMessage(message); } catch (_) {}
              };
              // On iCloud's own frames: report each setup and Find My call's
              // path, status, and client id, so iMCP can tell when the page's
              // session is whole and which client id Apple bound it to.
              if (/(^|\\.)icloud\\.com$/.test(location.hostname) && !window.__imcpFindMyCalls) {
                window.__imcpFindMyCalls = true;
                const watched = (value) => {
                  try {
                    const url = new URL(value, location.href);
                    if (!/(^|\\.)icloud\\.com$/.test(url.hostname)) return null;
                    return /\\/setup\\/ws\\/1\\/|\\/fmipservice\\//.test(url.pathname) ? url : null;
                  } catch (_) { return null; }
                };
                const tell = (url, status) => report(JSON.stringify({
                  request: url.pathname, status, clientId: url.searchParams.get("clientId") || ""
                }));
                const open = XMLHttpRequest.prototype.open;
                XMLHttpRequest.prototype.open = function (method, value, ...rest) {
                  const url = watched(value);
                  if (url) this.addEventListener("loadend", () => tell(url, this.status));
                  return open.call(this, method, value, ...rest);
                };
                const originalFetch = window.fetch;
                if (originalFetch) {
                  window.fetch = function (input, ...rest) {
                    const url = watched(typeof input === "string" ? input : (input && input.url) || String(input));
                    const pending = originalFetch.call(this, input, ...rest);
                    if (url) pending.then((response) => tell(url, response.status), () => tell(url, 0));
                    return pending;
                  };
                }
                return;
              }
              if (location.hostname !== "idmsa.apple.com" || window.__imcpFindMyAuthorization) return;
              window.__imcpFindMyAuthorization = true;
              report("identity frame loaded");
              const requestPath = (value) => {
                try {
                  const url = new URL(value, location.href);
                  return `${url.hostname}${url.pathname}`;
                } catch (_) { return "unknown"; }
              };
              const originalOpen = XMLHttpRequest.prototype.open;
              XMLHttpRequest.prototype.open = function (method, url, ...rest) {
                this.addEventListener("loadend", () => {
                  const path = requestPath(url);
                  if (path.endsWith("idmsa.apple.com/appleauth/auth/signin/complete") && this.status === 403) {
                    report(\(rejected));
                  }
                });
                return originalOpen.call(this, method, url, ...rest);
              };
              const accountValue = \(account);
              const passwordValue = \(password);
              const shown = (element) => element && element.offsetParent !== null && !element.disabled;
              const setValue = (element, value) => {
                element.focus();
                Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(element, value);
                element.dispatchEvent(new Event("input", { bubbles: true }));
                element.dispatchEvent(new Event("change", { bubbles: true }));
              };
              const submit = (element) => {
                for (const selector of ["#sign-in", "#continue", "button[type=submit]"]) {
                  const button = document.querySelector(selector);
                  if (shown(button)) { button.click(); return selector; }
                }
                const key = { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true };
                element.dispatchEvent(new KeyboardEvent("keydown", key));
                element.dispatchEvent(new KeyboardEvent("keyup", key));
                return "Enter";
              };
              let accountAttempts = 0;
              let passwordAttempts = 0;
              let signInClicks = 0;
              let lastClick = 0;
              const timer = setInterval(() => {
                const account = document.querySelector("#account_name_text_field, input[autocomplete=username], input[type=email]");
                const password = document.querySelector("#password_text_field, input[type=password]");
                const said = [...document.querySelectorAll("[role=alert], [aria-live], .form-message, .si-error-message")]
                  .map((element) => element.textContent || "").join(" ");
                if (passwordAttempts > 0 && /incorrect|not correct|wrong|locked/i.test(said)) {
                  report(\(rejected));
                  clearInterval(timer);
                  return;
                }
                if (shown(password) && !password.value && passwordAttempts < 1) {
                  passwordAttempts += 1;
                  if (shown(account) && !account.value) setValue(account, accountValue);
                  setValue(password, passwordValue);
                  lastClick = Date.now();
                  report(`password filled and submitted with ${submit(password)}`);
                } else if (shown(password) && password.value && signInClicks < 1 && Date.now() - lastClick > 3_000) {
                  const button = document.querySelector("#sign-in");
                  if (shown(button)) {
                    signInClicks += 1;
                    lastClick = Date.now();
                    button.click();
                    report("pressed Sign In again");
                  }
                } else if (shown(account) && !account.value && !shown(password) && accountAttempts < 1) {
                  accountAttempts += 1;
                  setValue(account, accountValue);
                  report(`account filled and submitted with ${submit(account)}`);
                }
              }, 700);
            })();
            """
    }

    private static func jsonLiteral(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}
