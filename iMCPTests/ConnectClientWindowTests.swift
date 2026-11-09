import Foundation
import XCTest

@testable import iMCP

final class ConnectClientWindowTests: XCTestCase {
    /// The README's setup examples are a hand copy of what the Connect window
    /// offers, so they are held to it here.
    func testTheReadmeShowsTheConnectWindowsSnippets() throws {
        let readme = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("README.md"),
            encoding: .utf8
        )
        let path = "/Applications/iMCP.app/Contents/MacOS/imcp-server"
        for client in ConnectClientSnippets.Client.allCases {
            let snippet = ConnectClientSnippets.snippet(for: client, serverPath: path)
            XCTAssertTrue(readme.contains(snippet), "README lacks the \(client.rawValue) snippet:\n\(snippet)")
        }
    }

    func testConnectSnippetsAllCarryTheServerPath() throws {
        let path = "/Applications/iMCP.app/Contents/MacOS/imcp-server"
        for client in ConnectClientSnippets.Client.allCases {
            XCTAssertTrue(
                ConnectClientSnippets.snippet(for: client, serverPath: path).contains(path),
                "\(client) snippet lost the path"
            )
        }
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(ConnectClientSnippets.json(serverPath: path).utf8))
                as? [String: Any]
        )
        let servers = try XCTUnwrap(json["mcpServers"] as? [String: Any])
        let imcp = try XCTUnwrap(servers["iMCP"] as? [String: Any])
        XCTAssertEqual(imcp["command"] as? String, path)
    }
}
