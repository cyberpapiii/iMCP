import AppKit
import Combine
import SwiftUI

/// The one place a person goes to hook any MCP client up to iMCP: the server
/// command, a snippet for their client, and a pairing code if they want to
/// skip the approval prompt. Replaces the per-client integrations the app
/// used to ship; MCP clients all take the same command.
@MainActor
final class ConnectClientWindowController: NSWindowController, NSWindowDelegate {
    typealias IssuePairingCode = @MainActor () -> (code: String, expiresAt: Date)

    private let visibility = ConnectClientWindowVisibility()

    convenience init(
        issuePairingCode: @escaping IssuePairingCode,
        pairingCodeEvents: AnyPublisher<PairingCodeIssuer.Event, Never>,
        pairedClients: PairedClientStore
    ) {
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: DesignTokens.Size.connectWindowWidth,
                height: DesignTokens.Size.connectWindowHeight
            ),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Connect a Client"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.contentView = NSHostingView(
            rootView: ConnectClientView(
                issuePairingCode: issuePairingCode,
                pairingCodeEvents: pairingCodeEvents,
                pairedClients: pairedClients,
                visibility: visibility
            )
        )
        window.delegate = self
    }

    override func showWindow(_ sender: Any?) {
        visibility.isOpen = true
        super.showWindow(sender)
    }

    func windowWillClose(_ notification: Notification) {
        visibility.isOpen = false
    }
}

/// Whether the Connect window is on screen. The window is kept when it
/// closes, so its view needs telling when nobody is looking: a countdown
/// must not run behind a closed window.
@MainActor
final class ConnectClientWindowVisibility: ObservableObject {
    @Published var isOpen = false
}

/// The pairing code as the Connect window shows it.
enum PairingCodeDisplay: Equatable {
    enum Ending: Equatable {
        case expired
        /// Guessed at three times.
        case discarded
        /// A client presented it, and pairs once its session is admitted.
        case redeemed
        /// The client that presented it is now paired.
        case paired(clientName: String)

        var text: String {
            switch self {
            case .expired: return "Expired"
            case .discarded, .redeemed: return "No longer valid"
            case .paired(let clientName): return "Paired with \(clientName)"
            }
        }

        var isPaired: Bool {
            if case .paired = self { return true }
            return false
        }
    }

    case none
    case live(code: String, expiresAt: Date)
    /// The code that was here stopped working. It is no longer shown.
    case ended(Ending)

    var expiresAt: Date? {
        if case .live(_, let expiresAt) = self { return expiresAt }
        return nil
    }

    func expiring(at now: Date) -> PairingCodeDisplay {
        guard let expiresAt, now >= expiresAt else { return self }
        return .ended(.expired)
    }

    /// The code on show stopped working before its expiry.
    func ending(_ event: PairingCodeIssuer.Event) -> PairingCodeDisplay {
        switch (self, event) {
        case (.live(let shown, _), .redeemed(let code)) where shown == code:
            return .ended(.redeemed)
        case (.live(let shown, _), .exhausted(let code)) where shown == code:
            return .ended(.discarded)
        default:
            return self
        }
    }

    /// A client has just paired for the first time. Only a pairing made with
    /// a code, while the code on show is the one a client presented, is that
    /// code's doing; any other state is unchanged.
    func pairing(_ outcome: PairingOutcome) -> PairingCodeDisplay {
        guard outcome.route == .pairingCode, let client = outcome.client, self == .ended(.redeemed) else {
            return self
        }
        return .ended(.paired(clientName: client.label))
    }

    /// The window has closed. "Paired" has been said; the client now lives
    /// in Settings, and the window offers a code again.
    func closing() -> PairingCodeDisplay {
        if case .ended(let ending) = self, ending.isPaired { return .none }
        return self
    }
}

struct ConnectClientView: View {
    /// Which Copy button was last pressed. A fresh press of the same one is a
    /// new value, so its "Copied" starts over.
    private struct Copied: Equatable {
        let label: String
        let press: Int
    }

    private static let copy = SteadyLabel.Face(text: "Copy")
    private static let copiedFace = SteadyLabel.Face(text: "Copied")

    let issuePairingCode: ConnectClientWindowController.IssuePairingCode
    let pairingCodeEvents: AnyPublisher<PairingCodeIssuer.Event, Never>
    let pairedClients: PairedClientStore
    @ObservedObject var visibility: ConnectClientWindowVisibility
    @State private var client: ConnectClientSnippets.Client = .json
    @State private var pairingCode = PairingCodeDisplay.none
    @State private var copied: Copied?
    @State private var presses = 0

    private var serverPath: String { Bundle.main.imcpServerPath }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                section("Server command") {
                    note(
                        "Any MCP client that can launch a local command can use iMCP. Point it at this executable."
                    )
                    snippetBox(serverPath, label: "command")
                }

                section("Set up your client") {
                    Picker("Client", selection: $client) {
                        ForEach(ConnectClientSnippets.Client.allCases) { client in
                            Text(client.rawValue).tag(client)
                        }
                    }
                    .labelsHidden()
                    if let hint = ConnectClientSnippets.hint(for: client) {
                        note(hint)
                            .transition(.reveal(.quick))
                    }
                    snippetBox(
                        ConnectClientSnippets.snippet(for: client, serverPath: serverPath),
                        label: "snippet"
                    )
                }
                .motion(.quick, value: client)

                section("Approval and pairing") {
                    note(
                        "The first time a client connects, iMCP asks you to approve it. Tick "
                            + "\"Always allow this client\" in that dialog and it never asks again. "
                            + "To skip the dialog entirely, give the client a one-time code."
                    )

                    pairing
                }
                .motion(.surface, value: pairingCode)
            }
            .padding(DesignTokens.Spacing.window)
        }
        .frame(width: DesignTokens.Size.connectWindowWidth, height: DesignTokens.Size.connectWindowHeight)
        .task(id: pairingCode.expiresAt) {
            guard let expiresAt = pairingCode.expiresAt else { return }
            try? await Task.sleep(for: .seconds(max(0, expiresAt.timeIntervalSinceNow)))
            if !Task.isCancelled { pairingCode = pairingCode.expiring(at: Date()) }
        }
        .task(id: copied) {
            guard copied != nil else { return }
            try? await Task.sleep(for: DesignTokens.Linger.confirmation)
            if !Task.isCancelled { copied = nil }
        }
        .onReceive(pairingCodeEvents) { event in
            pairingCode = pairingCode.ending(event)
        }
        .onReceive(pairedClients.pairingOutcomes) { outcome in
            // Nothing is marked behind a closed window.
            if visibility.isOpen { pairingCode = pairingCode.pairing(outcome) }
        }
        .onChange(of: visibility.isOpen) { _, isOpen in
            if !isOpen { pairingCode = pairingCode.closing() }
        }
    }

    /// The code, or what became of it, always in the same box; under it, how
    /// to use a code that still works.
    @ViewBuilder
    private var pairing: some View {
        switch pairingCode {
        case .none:
            Button("Generate Pairing Code", action: generate)
                .transition(.opacity)
        case .live(let code, let expiresAt):
            snippetBox(code, label: "code", font: DesignTokens.Typography.pairingCode)
            Text(
                "\(expiry(expiresAt)) · single use. Pass it as \(Text(verbatim: "imcp-server \(PairingCode.flag) \(code)").font(DesignTokens.Typography.code)), or set \(Text(verbatim: PairingCode.environmentVariable).font(DesignTokens.Typography.code)) for a spawned client."
            )
            .font(DesignTokens.Typography.detail)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
        case .ended(let ending):
            well {
                Label {
                    Text(ending.text)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                } icon: {
                    Image(systemName: "clock.badge.xmark")
                        .opacity(ending.isPaired ? 0 : 1)
                        .overlay {
                            SuccessTick(isDrawn: ending.isPaired, announcement: "Client paired")
                                .foregroundStyle(DesignTokens.StatusColor.ok)
                        }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("New Code", action: generate)
                    .controlSize(.small)
            }
        }
    }

    private func expiry(_ expiresAt: Date) -> Text {
        visibility.isOpen
            ? Text("Expires in \(Text(expiresAt, style: .timer).monospacedDigit())")
            : Text("Expires soon")
    }

    private func generate() {
        let issued = issuePairingCode()
        pairingCode = .live(code: issued.code, expiresAt: issued.expiresAt)
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.Typography.detail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Machine text to copy: monospaced, selectable, with its own Copy button.
    private func snippetBox(
        _ text: String,
        label: String,
        font: Font = DesignTokens.Typography.snippet
    ) -> some View {
        well {
            Text(text)
                .font(font)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                presses += 1
                copied = Copied(label: label, press: presses)
            } label: {
                SteadyLabel(
                    faces: [Self.copy, Self.copiedFace],
                    current: copied?.label == label ? Self.copiedFace : Self.copy
                )
            }
            .controlSize(.small)
        }
    }

    private func well<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            content()
        }
        .padding(DesignTokens.Spacing.md)
        .background(
            Color.secondary.opacity(DesignTokens.Opacity.well),
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.callout)
        )
    }
}

/// The ways an MCP client is told where `imcp-server` lives, as the Connect
/// window offers them.
enum ConnectClientSnippets {
    enum Client: String, CaseIterable, Identifiable {
        case json = "Any client (JSON)"
        case claudeCode = "Claude Code"
        case codex = "Codex CLI"
        case cursor = "Cursor"
        case amp = "Amp"

        var id: String { rawValue }
    }

    static func snippet(for client: Client, serverPath: String) -> String {
        switch client {
        case .json:
            return json(serverPath: serverPath)
        case .claudeCode:
            return "claude mcp add --scope user iMCP -- \(serverPath)"
        case .codex:
            return "codex mcp add iMCP -- \(serverPath)"
        case .cursor:
            return json(serverPath: serverPath)
        case .amp:
            return "amp mcp add iMCP -- \(serverPath)"
        }
    }

    /// Where the snippet goes, when it is not a command to run.
    static func hint(for client: Client) -> String? {
        switch client {
        case .json:
            return "Add this to the client's MCP configuration file under \"mcpServers\"."
        case .cursor:
            return "Add this to ~/.cursor/mcp.json, or Cursor Settings › MCP › Add new server."
        case .claudeCode, .codex, .amp:
            return "Run this in Terminal."
        }
    }

    static func json(serverPath: String) -> String {
        """
        {
          "mcpServers": {
            "iMCP": {
              "command": "\(serverPath)"
            }
          }
        }
        """
    }
}
