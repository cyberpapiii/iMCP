import Foundation
import OrderedCollections
import JSONSchema
import MCP
import Ontology

public enum ToolResult: Sendable {
    case json(Data)
    case binary(mimeType: String, data: Data)
}

public struct Tool: Sendable {
    let name: String
    let description: String
    let inputSchema: JSONSchema
    let annotations: MCP.Tool.Annotations
    private let implementation: @Sendable ([String: Value]) async throws -> ToolResult

    /// A tool whose input schema is its `arguments`, in order, accepting no
    /// other key.
    init(
        name: String,
        description: String,
        arguments: [any ToolArgumentDeclaration],
        annotations: MCP.Tool.Annotations,
        implementation: @Sendable @escaping ([String: Value]) async throws -> Value
    ) {
        self.init(
            name: name,
            description: description,
            inputSchema: Self.inputSchema(arguments),
            annotations: annotations,
            result: { input in
                let value = try await implementation(input)
                switch value {
                case .data(let mimeType?, let data)
                where mimeType.hasPrefix("audio/") || mimeType.hasPrefix("image/"):
                    return .binary(mimeType: mimeType, data: data)
                default:
                    return try Self.encodeJSON(value)
                }
            }
        )
    }

    init<T: Encodable>(
        name: String,
        description: String,
        arguments: [any ToolArgumentDeclaration],
        annotations: MCP.Tool.Annotations,
        implementation: @Sendable @escaping ([String: Value]) async throws -> T
    ) {
        self.init(
            name: name,
            description: description,
            inputSchema: Self.inputSchema(arguments),
            annotations: annotations,
            result: { input in try Self.encodeJSON(try await implementation(input)) }
        )
    }

    /// An object of `arguments`, accepting no other key: a tool's input, or
    /// an object nested in it.
    static func inputSchema(_ arguments: [any ToolArgumentDeclaration], description: String? = nil) -> JSONSchema {
        .object(
            description: description,
            properties: OrderedDictionary(uniqueKeysWithValues: arguments.flatMap(\.properties)),
            required: arguments.flatMap(\.requiredKeys),
            additionalProperties: false
        )
    }

    private init(
        name: String,
        description: String,
        inputSchema: JSONSchema,
        annotations: MCP.Tool.Annotations,
        result implementation: @Sendable @escaping ([String: Value]) async throws -> ToolResult
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.implementation = implementation
    }

    func preceded(by step: @Sendable @escaping () async throws -> Void) -> Tool {
        let implementation = self.implementation
        return Tool(
            name: name,
            description: description,
            inputSchema: inputSchema,
            annotations: annotations,
            result: { input in
                try await step()
                return try await implementation(input)
            }
        )
    }

    public func callAsFunction(_ input: [String: Value]) async throws -> ToolResult {
        try await implementation(input)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> ToolResult {
        let encoder = JSONEncoder()
        encoder.userInfo[Ontology.DateTime.timeZoneOverrideKey] = TimeZone.current
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return .json(try encoder.encode(value))
    }
}
