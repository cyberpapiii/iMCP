import XCTest

@testable import iMCP

final class CallToolDispatchTests: XCTestCase {
    /// Tools are looked up by name, so two services claiming the
    /// same tool name make one of them permanently unreachable. Which one wins
    /// depends on registry order, so the failure would look intermittent.
    func testUniqueToolNamesAcrossRegistry() throws {
        let definitions = try ToolCatalog.definitions(from: ServiceRegistry.entries)
        let names = definitions.map(\.localTool.name)
        XCTAssertEqual(Set(names).count, names.count, "Duplicate tool names: \(names)")
    }

    private func catalog() throws -> ToolCatalog {
        try ToolCatalog(entries: ServiceRegistry.entries)
    }

    private func utilitiesID() throws -> String {
        try XCTUnwrap(catalog().definitions.first { $0.localTool.name == "utilities_beep" }).serviceID
    }

    func testEnabledToolIsCallable() throws {
        let callable = try catalog().callable(named: "utilities_beep", enabled: [try utilitiesID()])
        XCTAssertEqual(callable.localTool.name, "utilities_beep")
        let encoded = ToolCatalog.jsonText(from: Data("{\"ok\":true}".utf8))
        XCTAssertEqual(encoded.text, "{\"ok\":true}")
        XCTAssertFalse(encoded.isError)
    }

    func testOnlyEnabledServicesToolsAreListed() throws {
        let catalog = try catalog()
        let utilities = try utilitiesID()
        XCTAssertEqual(catalog.tools(enabled: []), [])
        let listed = catalog.tools(enabled: [utilities]).map(\.name)
        XCTAssertTrue(listed.contains("utilities_beep"))
        XCTAssertEqual(
            Set(listed),
            Set(catalog.definitions.filter { $0.serviceID == utilities }.map(\.localTool.name))
        )
    }

    func testUnknownNameAndDisabledServiceUseDifferentErrorTexts() throws {
        let catalog = try catalog()
        let utilities = try utilitiesID()
        XCTAssertThrowsError(try catalog.callable(named: "unknown_tool", enabled: [utilities])) { error in
            XCTAssertEqual(sanitizedToolErrorMessage(for: error), "Tool not found: unknown_tool")
        }
        XCTAssertThrowsError(try catalog.callable(named: "utilities_beep", enabled: [])) { error in
            XCTAssertEqual(
                sanitizedToolErrorMessage(for: error),
                "Utilities is off. Turn it on in the iMCP menu bar."
            )
        }
        XCTAssertEqual(catalog.definitions.first { $0.serviceID == utilities }?.serviceName, "Utilities")
    }

    func testNonUTF8JSONIsError() {
        let encoded = ToolCatalog.jsonText(from: Data([0xFF, 0xFE, 0xFD]))
        XCTAssertTrue(encoded.isError)
        XCTAssertNotEqual(encoded.text, "{}")
    }

    func testResultsMapToTheirContentKinds() {
        let png = ToolCatalog.callResult(for: .binary(mimeType: "image/png", data: Data([1])))
        XCTAssertEqual(png.content, [.image(data: "AQ==", mimeType: "image/png", annotations: nil, _meta: nil)])
        XCTAssertEqual(png.isError, false)
        let audio = ToolCatalog.callResult(for: .binary(mimeType: "audio/wav", data: Data([1])))
        XCTAssertEqual(audio.content, [.audio(data: "AQ==", mimeType: "audio/wav", annotations: nil, _meta: nil)])
        let other = ToolCatalog.callResult(for: .binary(mimeType: "application/pdf", data: Data([1])))
        XCTAssertEqual(other.content, [.text(text: "Unsupported binary result", annotations: nil, _meta: nil)])
        XCTAssertEqual(other.isError, true)
        let failed = ToolCatalog.errorResult(for: CocoaError(.fileNoSuchFile), toolName: "x")
        XCTAssertEqual(
            failed.content,
            [.text(text: "Tool execution failed. See iMCP logs for details.", annotations: nil, _meta: nil)]
        )
        XCTAssertEqual(failed.isError, true)
    }
}

/// Every byte of every schema lands in a client's context on every session,
/// and some clients reject whole tools over one property name. Keeps both
/// classes of regression out of the tool surface.
final class ToolSchemaHygieneTests: XCTestCase {
    private func inputSchemas() throws -> [(name: String, properties: [String: Value])] {
        try ToolCatalog.definitions(from: ServiceRegistry.entries).map { definition in
            let properties = definition.mcpTool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
            return (definition.localTool.name, properties)
        }
    }

    /// The Anthropic API rejects tool property names outside `[a-zA-Z0-9_.-]`,
    /// which silently drops the tool from every Claude client. `contacts_update`
    /// shipped an `@id` property that way once.
    func testPropertyNamesAreAcceptedByEveryClient() throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        for (name, properties) in try inputSchemas() {
            for key in properties.keys {
                XCTAssertTrue(
                    key.unicodeScalars.allSatisfy(allowed.contains) && !key.isEmpty && key.count <= 64,
                    "\(name) property \(key) would be rejected"
                )
            }
        }
    }

    /// Aliases are accepted at call time (see `ToolArgument.date(alias:)`), but
    /// documenting both spellings doubles the schema for no information.
    func testNoDateBoundIsDocumentedTwice() throws {
        for (name, properties) in try inputSchemas() {
            for key in properties.keys {
                let description = properties[key]?.objectValue?["description"]?.stringValue ?? ""
                XCTAssertFalse(description.hasPrefix("Alias of"), "\(name).\(key) is a documented alias")
            }
            XCTAssertFalse(
                properties.keys.contains("start") && properties.keys.contains("startDate"),
                "\(name) documents both start and startDate"
            )
        }
    }

    /// The server clamps every `limit`; a schema that hides the ceiling makes
    /// a client believe it received everything it asked for.
    func testEveryLimitAdvertisesItsCeiling() throws {
        for (name, properties) in try inputSchemas() {
            guard let limit = properties["limit"]?.objectValue else { continue }
            XCTAssertNotNil(limit["maximum"], "\(name).limit has no maximum")
        }
    }

}

/// Clients decide what to run without asking from these hints, so each one
/// has to be true. Decide by reading the tool's closure, not its name:
///
/// - `read`: only returns data that already exists. Writing user data,
///   recording from the camera, microphone, or screen, or doing anything a
///   person can perceive (a sound, a running shortcut) is not a read.
/// - `add`: creates something new, or has a local, momentary effect.
/// - `destroy`: can replace or remove existing data, or has an effect that
///   leaves this Mac and cannot be taken back.
/// - `open`: the call itself contacts a network service or another device.
///   `local`: it only touches data already on this Mac.
///
/// `idempotentHint` stays unset: claim it only for a tool whose second
/// identical call succeeds and changes nothing, with a test that proves it.
final class ToolAnnotationTests: XCTestCase {
    private static let table = """
        browser_history_search read local
        calendars_list read local
        calls_fetch read local
        capture_record_audio add local
        capture_take_picture add local
        capture_take_screenshot add local
        contacts_create add local
        contacts_me read local
        contacts_search read local
        contacts_update destroy local
        events_create add local
        events_delete destroy local
        events_fetch read local
        events_update destroy local
        location_devices read open
        location_friend read local
        location_friends read local
        location_history read local
        location_now read open
        location_people read open
        location_place_delete destroy local
        location_place_set destroy local
        location_places read local
        location_ring destroy open
        location_timeline read open
        location_visits read open
        maps_directions read open
        maps_eta read open
        maps_explore read open
        maps_generate read open
        maps_geocode read open
        maps_reverse_geocode read open
        maps_search read open
        messages_fetch read local
        notes_fetch read local
        notes_folders read local
        notes_search read local
        notifications_fetch read local
        photos_albums read local
        photos_fetch_image read local
        photos_search read open
        reminders_create add local
        reminders_delete destroy local
        reminders_fetch read local
        reminders_lists read local
        reminders_update destroy local
        screentime_device_activity read local
        screentime_usage read local
        screentime_web_usage read local
        shortcuts_list read local
        shortcuts_run destroy open
        utilities_beep add local
        weather_current read open
        weather_daily read open
        weather_hourly read open
        weather_minute read open
        """

    func testEveryToolAnnotationMatchesTheTable() throws {
        // Weather is registered only in Release builds; its tools ship all the same.
        var entries = ServiceRegistry.entries
        if !entries.contains(where: { $0.service is WeatherService }) {
            entries.append(ServiceRegistry.weather)
        }
        let definitions = try ToolCatalog.definitions(from: entries)

        var expected: [String: (effect: String, reach: String)] = [:]
        for line in Self.table.split(separator: "\n") {
            let fields = line.split(separator: " ").map(String.init)
            XCTAssertEqual(fields.count, 3, "Malformed row: \(line)")
            XCTAssertTrue(["read", "add", "destroy"].contains(fields[1]), "Unknown effect: \(line)")
            XCTAssertTrue(["local", "open"].contains(fields[2]), "Unknown reach: \(line)")
            expected[fields[0]] = (fields[1], fields[2])
        }

        XCTAssertEqual(
            Set(definitions.map(\.localTool.name)),
            Set(expected.keys),
            "Add, rename, or remove the tool's row in the table"
        )
        for definition in definitions {
            let name = definition.localTool.name
            guard let row = expected[name] else { continue }
            let hints = definition.mcpTool.annotations
            let destructive: Bool? = row.effect == "read" ? nil : row.effect == "destroy"
            XCTAssertEqual(hints.readOnlyHint, row.effect == "read", "\(name) readOnlyHint")
            XCTAssertEqual(hints.destructiveHint, destructive, "\(name) destructiveHint")
            XCTAssertNil(hints.idempotentHint, "\(name) idempotentHint")
            XCTAssertEqual(hints.openWorldHint, row.reach == "open", "\(name) openWorldHint")
            XCTAssertFalse((hints.title ?? "").isEmpty, "\(name) has no title")
        }
    }
}
