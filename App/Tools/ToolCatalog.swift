import Foundation
import MCP
import OSLog

struct ToolDefinition: Sendable {
    let serviceID: String
    let serviceName: String
    let localTool: Tool
    let mcpTool: MCP.Tool
}

/// Every tool the services offer, and the rules for listing and calling one.
/// Built once; which services are on is passed in with each request.
struct ToolCatalog: Sendable {
    let definitions: [ToolDefinition]
    private let byName: [String: ToolDefinition]

    init(entries: [ServiceEntry]) throws {
        definitions = try Self.definitions(from: entries)
        var byName: [String: ToolDefinition] = [:]
        for definition in definitions {
            let toolName = definition.localTool.name
            if byName[toolName] != nil {
                Logger.server.error("Duplicate tool name in registry: \(toolName)")
            } else {
                byName[toolName] = definition
            }
        }
        self.byName = byName
    }

    static func definitions(from entries: [ServiceEntry]) throws -> [ToolDefinition] {
        var definitions: [ToolDefinition] = []
        for entry in entries {
            for tool in entry.service.callableTools {
                definitions.append(
                    ToolDefinition(
                        serviceID: entry.id,
                        serviceName: entry.name,
                        localTool: tool,
                        mcpTool: .init(
                            name: tool.name,
                            description: tool.description,
                            inputSchema: try Value(tool.inputSchema),
                            annotations: tool.annotations
                        )
                    )
                )
            }
        }
        return definitions
    }

    func tools(enabled enabledServiceIDs: Set<String>) -> [MCP.Tool] {
        definitions.filter { enabledServiceIDs.contains($0.serviceID) }.map(\.mcpTool)
    }

    /// Unknown names and known-but-disabled services must not share a string.
    func callable(named name: String, enabled enabledServiceIDs: Set<String>) throws -> ToolDefinition {
        guard let definition = byName[name] else {
            throw ToolFailure("Tool not found: \(name)")
        }
        guard enabledServiceIDs.contains(definition.serviceID) else {
            throw ToolFailure("\(definition.serviceName) is off. Turn it on in the iMCP menu bar.")
        }
        return definition
    }

    func call(
        named name: String,
        arguments: [String: Value],
        enabled enabledServiceIDs: Set<String>
    ) async throws -> CallTool.Result {
        let definition = try callable(named: name, enabled: enabledServiceIDs)
        return Self.callResult(for: try await definition.localTool.callAsFunction(arguments))
    }

    static func callResult(for result: ToolResult) -> CallTool.Result {
        switch result {
        case .binary(let mimeType, let data) where mimeType.hasPrefix("audio/"):
            return CallTool.Result(
                content: [.audio(data: data.base64EncodedString(), mimeType: mimeType, annotations: nil, _meta: nil)],
                isError: false
            )
        case .binary(let mimeType, let data) where mimeType.hasPrefix("image/"):
            return CallTool.Result(
                content: [.image(data: data.base64EncodedString(), mimeType: mimeType, annotations: nil, _meta: nil)],
                isError: false
            )
        case .json(let data):
            let encoded = jsonText(from: data)
            return CallTool.Result(
                content: [.text(text: encoded.text, annotations: nil, _meta: nil)],
                isError: encoded.isError
            )
        case .binary:
            return CallTool.Result(
                content: [.text(text: "Unsupported binary result", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }

    /// What a failed call sends back. Only `ClientFacingError` text crosses;
    /// the rest stays in the log.
    static func errorResult(for error: Error, toolName: String) -> CallTool.Result {
        Logger.server.error("Error executing tool \(toolName): \(error.localizedDescription)")
        return CallTool.Result(
            content: [.text(text: sanitizedToolErrorMessage(for: error), annotations: nil, _meta: nil)],
            isError: true
        )
    }

    /// Non-UTF-8 JSON is an error.
    static func jsonText(from data: Data) -> (text: String, isError: Bool) {
        if let text = String(data: data, encoding: .utf8) {
            return (text, false)
        }
        return ("Tool result is not valid UTF-8 JSON", true)
    }
}
