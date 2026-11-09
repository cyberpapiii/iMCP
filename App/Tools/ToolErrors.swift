import Foundation

/// Errors that opt in to crossing the trust boundary verbatim. A conforming
/// type must carry no paths, no SQL, and no NSError payloads — only text a
/// tool caller can act on.
/// Declare the conformance on the type itself.
protocol ClientFacingError: LocalizedError {}

/// Tool errors routinely wrap filesystem paths, SQLite messages, and NSError
/// domains. None of that belongs on the wire to an MCP client. The detail
/// stays in the server-side log, and this function is the one place that
/// decides what crosses the trust boundary.
func sanitizedToolErrorMessage(
    for error: Error,
    fallback: String = "Tool execution failed. See iMCP logs for details."
) -> String {
    (error as? ClientFacingError)?.errorDescription ?? fallback
}

/// An argument the caller can fix. The message names what was missing or
/// unusable, so an MCP client can correct the call instead of retrying it
/// blind against the generic failure text. Authored strings only, plus at
/// most the caller's own argument echoed back: nothing here may carry a path,
/// a query, or a system error's description.
struct ToolInputError: ClientFacingError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

/// A failure the caller cannot fix by changing an argument but can act on: a
/// permission the user must grant, something that was not found, a timeout.
/// Same content rule as `ToolInputError`.
struct ToolFailure: ClientFacingError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
