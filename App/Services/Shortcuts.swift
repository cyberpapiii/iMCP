import Foundation
import OSLog

private let log = Logger.service("shortcuts")

final class PipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.withLock {
            data.append(newData)
        }
    }

    func value() -> Data {
        lock.withLock { data }
    }
}

/// Collects a pipe's output as it arrives. A child that writes more than a
/// pipe holds (about 64 KB) blocks until someone reads, so reading only
/// after exit can hang it forever.
func drain(_ pipe: Pipe) -> PipeBuffer {
    let buffer = PipeBuffer()
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if !data.isEmpty {
            buffer.append(data)
        }
    }
    return buffer
}

/// The shortcut has already run by the time this is read, so nothing here
/// may throw: a missing file means no output, and bytes that are not UTF-8
/// are kept with replacement characters rather than reported as a failure.
func shortcutOutputText(at url: URL) -> String? {
    (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
}

final class ShortcutsService: Service {
    static let shared = ShortcutsService()

    private let shortcutsPath = "/usr/bin/shortcuts"
    private let executionTimeout: Duration = .seconds(300)
    private let listTimeout: Duration = .seconds(60)

    private static let name = ToolArgument.required(
        "name",
        description: "Exact name of the shortcut, as listed by shortcuts_list"
    )
    private static let input = ToolArgument.string(
        "input",
        description: "Text passed to the shortcut as its input"
    )

    var tools: [Tool] {
        Tool(
            name: "shortcuts_list",
            description: "List the names of every shortcut installed on this Mac",
            arguments: [],
            annotations: .init(
                title: "List Shortcuts",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            try await self.listShortcuts()
        }

        Tool(
            name: "shortcuts_run",
            description:
                "Run a shortcut by name and return its text output. Fails if the shortcut runs longer than \(executionTimeout.components.seconds / 60) minutes.",
            arguments: [Self.name, Self.input],
            annotations: .init(
                title: "Run Shortcut",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: true
            )
        ) { arguments in
            try await self.runShortcut(name: try Self.name(arguments), input: try Self.input(arguments))
        }
    }

    /// `subject` names the run in the log and in the failure a client reads.
    private func shortcuts(
        _ arguments: [String],
        subject: String,
        within limit: Duration,
        timeoutError: ToolFailure
    ) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shortcutsPath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let outputBuffer = drain(outputPipe)
        let errorBuffer = drain(errorPipe)
        defer {
            for handle in [outputPipe.fileHandleForReading, errorPipe.fileHandleForReading] {
                handle.readabilityHandler = nil
                handle.closeFile()
            }
        }
        let stderr = { String(data: errorBuffer.value(), encoding: .utf8) ?? "Unknown error" }

        do {
            try await withDeadline(
                limit,
                throwing: timeoutError,
                onTimeout: {
                    if process.isRunning { process.terminate() }
                }
            ) { report in
                process.terminationHandler = { _ in report(.success(())) }
                do {
                    try process.run()
                } catch {
                    report(.failure(error))
                    return
                }
                if !process.isRunning {
                    report(.success(()))
                }
            }
        } catch {
            if !errorBuffer.value().isEmpty {
                log.error("\(subject) stderr: \(stderr())")
            }
            log.error("Failed to run \(subject): \(error.localizedDescription)")
            throw error
        }

        guard process.terminationStatus == 0 else {
            log.error("\(subject) failed: \(stderr())")
            throw ToolFailure("\(subject) failed. See iMCP logs for details.")
        }
        return outputBuffer.value()
    }

    private func listShortcuts() async throws -> Value {
        let outputData = try await shortcuts(
            ["list"],
            subject: "shortcuts list",
            within: listTimeout,
            timeoutError: ToolFailure("shortcuts list timed out after \(listTimeout.components.seconds) seconds")
        )

        guard let output = String(data: outputData, encoding: .utf8) else {
            return .array([])
        }

        let shortcuts =
            output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        log.info("Found \(shortcuts.count) shortcuts")

        return .array(shortcuts.map { .string($0) })
    }

    private func runShortcut(name: String, input: String?) async throws -> Value {
        log.info("Running shortcut: \(name)")

        guard !name.hasPrefix("-") else {
            throw ToolInputError("Shortcut name must not start with -")
        }

        let tempDir = FileManager.default.temporaryDirectory
        let outputFileURL = tempDir.appendingPathComponent("shortcut_output_\(UUID().uuidString).txt")

        var arguments = ["run", name, "--output-path", outputFileURL.path]
        var inputFileURL: URL?

        if let input = input {
            let inputURL = tempDir.appendingPathComponent("shortcut_input_\(UUID().uuidString).txt")
            try input.write(to: inputURL, atomically: true, encoding: .utf8)
            arguments.append(contentsOf: ["--input-path", inputURL.path])
            inputFileURL = inputURL
        }

        defer {
            if let inputURL = inputFileURL {
                try? FileManager.default.removeItem(at: inputURL)
            }
            try? FileManager.default.removeItem(at: outputFileURL)
        }

        _ = try await shortcuts(
            arguments,
            subject: "Shortcut '\(name)'",
            within: executionTimeout,
            timeoutError: ToolFailure(
                "Shortcut '\(name)' timed out after \(executionTimeout.components.seconds / 60) minutes"
            )
        )

        let output = shortcutOutputText(at: outputFileURL)

        log.info("Shortcut '\(name)' completed successfully")

        if let output = output, !output.isEmpty {
            return .object([
                "success": .bool(true),
                "shortcut": .string(name),
                "output": .string(output),
            ])
        }

        return .object([
            "success": .bool(true),
            "shortcut": .string(name),
        ])
    }
}
