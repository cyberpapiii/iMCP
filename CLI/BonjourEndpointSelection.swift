enum BonjourEndpointSelectionError: Error, Equatable {
    case noMatch
    case ambiguous(count: Int)
}

/// Position of a candidate in the mDNS conflict-renaming sequence: 0 for the
/// plain `iMCP` registration, N for a record macOS renamed to `iMCP (N)`,
/// `nil` for a record that is not ours at all.
///
/// mDNSResponder renames a registration whose name is already claimed on the
/// network. Relaunching the app while the previous instance's record is still
/// being withdrawn is enough to trigger it, and the rename sticks for the life
/// of that process. Treating `iMCP (2)` as a stranger left the CLI unable to
/// find a running app by Bonjour at all, retrying every five seconds forever.
func imcpEndpointConflictIndex(_ endpointDescription: String) -> Int? {
    // A Bonjour endpoint description is `<instance>.<type>.<domain>.`, and the
    // instance name is the only part that identifies us. A bare hostname record
    // such as Example-MacBook-Pro._mcp._tcp.local. belongs to some other MCP server.
    let name: String
    if let typeSeparator = endpointDescription.range(of: "._") {
        name = String(endpointDescription[..<typeSeparator.lowerBound])
    } else {
        name = endpointDescription
    }

    if name == WireContract.bonjourInstanceName {
        return 0
    }

    // The space in a renamed instance arrives escaped as `\032` over the wire
    // and unescaped through some description paths, so accept both spellings.
    for spaceSpelling in ["\\032", " "] {
        let prefix = WireContract.bonjourInstanceName + spaceSpelling + "("
        guard name.hasPrefix(prefix), name.hasSuffix(")") else { continue }
        guard let index = Int(name.dropFirst(prefix.count).dropLast()), index > 0 else { continue }
        return index
    }

    return nil
}

/// Split out so the selection rule can be tested without a live NWBrowser.
///
/// The unrenamed record wins when there is one: a rename means some other
/// registration already holds the plain name, and that one is the app the
/// system considers current. Renamed records are only consulted when no plain
/// `iMCP` record is on the network, which is the case once a withdrawn record
/// finally expires.
func selectUniqueIMCPEndpointDescription(from descriptions: [String]) throws(BonjourEndpointSelectionError) -> String {
    let candidates = descriptions.compactMap { description in
        imcpEndpointConflictIndex(description).map { (description: description, index: $0) }
    }
    guard !candidates.isEmpty else { throw .noMatch }

    let unrenamed = candidates.filter { $0.index == 0 }
    if !unrenamed.isEmpty {
        guard unrenamed.count == 1, let selected = unrenamed.first else {
            throw .ambiguous(count: unrenamed.count)
        }
        return selected.description
    }

    guard candidates.count == 1, let selected = candidates.first else {
        throw .ambiguous(count: candidates.count)
    }
    return selected.description
}

/// What one browse result means for discovery. A result with no record of
/// ours yet (only another local `_mcp._tcp` server has answered), or with two
/// while one is being withdrawn, is not an answer: the next result usually
/// carries the app, so discovery keeps browsing. Only a selected endpoint,
/// a failed browser, the endpoint file, or the timeout ends the wait.
enum BonjourBrowseStep: Equatable {
    case connect(endpointDescription: String)
    case keepBrowsing(BonjourEndpointSelectionError)
}

func bonjourBrowseStep(for descriptions: [String]) -> BonjourBrowseStep {
    do {
        return .connect(endpointDescription: try selectUniqueIMCPEndpointDescription(from: descriptions))
    } catch {
        return .keepBrowsing(error)
    }
}
