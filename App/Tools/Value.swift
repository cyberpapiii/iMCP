@_exported import enum MCP.Value

extension Value {
    /// A schema.org `ItemList` of `items`, with `extra` keys alongside them.
    static func itemList(_ items: [Value], extra: [String: Value] = [:]) -> Value {
        var list: [String: Value] = [
            "@context": "https://schema.org",
            "@type": "ItemList",
            "itemListElement": .array(items),
        ]
        list.merge(extra) { listKey, _ in listKey }
        return .object(list)
    }
}
