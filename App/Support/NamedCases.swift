/// The names a tool accepts for a framework enum, one entry per case, in the
/// order its schema lists them. Parsing, naming, and the schema's `enum` all
/// read this one table, so they cannot disagree.
struct NamedCases<Case: Equatable> {
    let entries: [(name: String, value: Case)]

    init(_ entries: [(name: String, value: Case)]) {
        self.entries = entries
    }

    var names: [String] { entries.map(\.name) }

    func name(of value: Case) -> String? {
        entries.first { $0.value == value }?.name
    }
}

extension NamedCases where Case: RawRepresentable & CaseIterable, Case.RawValue == String {
    init() {
        self.init(Case.allCases.map { (name: $0.rawValue, value: $0) })
    }
}
