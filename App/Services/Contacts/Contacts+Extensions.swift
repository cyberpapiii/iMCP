import Contacts
import JSONSchema
import Ontology
import OrderedCollections

/// Maps the short label names tools accept ("mobile", "work", "home") onto
/// Contacts framework label constants. Anything else passes through as a
/// custom label.
enum CNContactLabel {
    static func from(string: String) -> String {
        switch string.lowercased() {
        case "mobile": return CNLabelPhoneNumberMobile
        case "work": return CNLabelWork
        case "home": return CNLabelHome
        default: return string
        }
    }
}

/// What a `contacts_create` or `contacts_update` call asked for, parsed with
/// no contact touched. A nil field was not sent and is left as it was.
struct ContactFields {
    /// The postal fields an entry sent, by key; a missing one keeps the stored
    /// value.
    typealias PostalAddress = [String: String]

    var givenName: String?
    var familyName: String?
    var organizationName: String?
    var jobTitle: String?
    /// By label. An empty number or address removes the first value with
    /// that label.
    var phoneNumbers: [String: String]?
    var emailAddresses: [String: String]?
    var postalAddresses: [String: PostalAddress]?
    var birthday: DateComponents?

    /// The postal fields a caller may send, and the address property each sets.
    static let postalFields: [(key: String, path: ReferenceWritableKeyPath<CNMutablePostalAddress, String>)] = [
        ("street", \.street), ("city", \.city), ("state", \.state), ("postalCode", \.postalCode),
        ("country", \.country),
    ]

    /// contacts_create's fields: a given name that says something is required.
    static let create = fields(
        givenName: ToolArgument("givenName", .string(), isRequired: true) { present in
            // Contacts saves a card with a blank name, and nothing would find it.
            guard let present else { throw ToolInputError("Given name is required") }
            let name = try ArgumentValue.string(present, "givenName")
            guard name.contains(where: { !$0.isWhitespace }) else { throw ToolInputError("Given name is required") }
            return name
        }
    )

    /// contacts_update's fields: every one optional.
    static let update = fields(givenName: .string("givenName"))

    private static func fields(givenName: ToolArgument<String?>) -> ToolArgument<ContactFields> {
        let familyName = ToolArgument<String?>.string("familyName")
        let organizationName = ToolArgument<String?>.string("organizationName")
        let jobTitle = ToolArgument<String?>.string("jobTitle")
        let phoneNumbers = labelled(
            "phoneNumbers",
            labels: ["mobile", "work", "home"],
            entry: .string()
        ) { try ArgumentValue.string($0, $1) }
        let emailAddresses = labelled(
            "emailAddresses",
            labels: ["work", "home"],
            entry: .string()
        ) { try ArgumentValue.string($0, $1) }
        let postalAddresses = labelled(
            "postalAddresses",
            labels: ["work", "home"],
            entry: .object(
                properties: OrderedDictionary(uniqueKeysWithValues: postalFields.map { ($0.key, JSONSchema.string()) })
            )
        ) { value, key in
            let fields = try ArgumentValue.object(value, key)
            var address: PostalAddress = [:]
            for field in postalFields {
                address[field.key] = try ArgumentValue.optional(fields, field.key) {
                    try ArgumentValue.string($0, "\(key).\($1)")
                }
            }
            return address
        }
        let all: [any ToolArgumentDeclaration] = [
            givenName, familyName, organizationName, jobTitle, phoneNumbers, emailAddresses, postalAddresses,
            birthday,
        ]
        return ToolArgument(properties: all.flatMap(\.properties), required: all.flatMap(\.requiredKeys)) {
            arguments in
            ContactFields(
                givenName: try givenName(arguments),
                familyName: try familyName(arguments),
                organizationName: try organizationName(arguments),
                jobTitle: try jobTitle(arguments),
                phoneNumbers: try phoneNumbers(arguments),
                emailAddresses: try emailAddresses(arguments),
                postalAddresses: try postalAddresses(arguments),
                birthday: try birthday(arguments)
            )
        }
    }

    /// A day and a month, and optionally a year, each inside its bounds.
    private static let birthday: ToolArgument<DateComponents?> = {
        let parts: [(key: String, range: ClosedRange<Int>?)] = [("day", 1 ... 31), ("month", 1 ... 12), ("year", nil)]
        let schema = JSONSchema.object(
            properties: OrderedDictionary(
                uniqueKeysWithValues: parts.map {
                    ($0.key, JSONSchema.integer(minimum: $0.range?.lowerBound, maximum: $0.range?.upperBound))
                }
            ),
            required: ["day", "month"]
        )
        return ToolArgument("birthday", schema) { present in
            guard let present else { return nil }
            let fields = try ArgumentValue.object(present, "birthday")
            var values: [String: Int] = [:]
            for part in parts {
                let key = "birthday.\(part.key)"
                guard let value = try presentArgument(fields, part.key).map({ try ArgumentValue.wholeNumber($0, key) })
                else { continue }
                if let range = part.range, !range.contains(value) {
                    throw ToolInputError("\(key) must be between \(range.lowerBound) and \(range.upperBound)")
                }
                values[part.key] = value
            }
            guard let day = values["day"], let month = values["month"] else {
                throw ToolInputError("birthday needs a day and a month")
            }
            return DateComponents(year: values["year"], month: month, day: day)
        }
    }()

    /// A label-to-entry object. Any label is accepted; `labels` are the ones
    /// the schema names. An entry that is JSON null is not sent.
    private static func labelled<Entry>(
        _ key: String,
        labels: [String],
        entry: JSONSchema,
        _ read: @escaping @Sendable (Value, String) throws -> Entry
    ) -> ToolArgument<[String: Entry]?> {
        ToolArgument(
            key,
            .object(
                properties: OrderedDictionary(uniqueKeysWithValues: labels.map { ($0, entry) }),
                additionalProperties: true
            )
        ) { present in
            guard let present else { return nil }
            var result: [String: Entry] = [:]
            for (label, value) in try ArgumentValue.object(present, key) where value != .null {
                result[label] = try read(value, "\(key).\(label)")
            }
            return result
        }
    }
}

extension CNMutableContact {
    /// Applies the fields that were sent; the rest keep their values. A
    /// labelled entry (phone, email, postal address) changes the first
    /// existing value with that label in place, or adds one; see `merge`.
    func populate(from fields: ContactFields) {
        if let givenName = fields.givenName { self.givenName = givenName }
        if let familyName = fields.familyName { self.familyName = familyName }
        if let organizationName = fields.organizationName { self.organizationName = organizationName }
        if let jobTitle = fields.jobTitle { self.jobTitle = jobTitle }

        if let phoneNumbers = fields.phoneNumbers {
            self.phoneNumbers = merge(phoneNumbers, into: self.phoneNumbers) {
                $1.isEmpty ? nil : CNPhoneNumber(stringValue: $1)
            }
        }

        if let emailAddresses = fields.emailAddresses {
            self.emailAddresses = merge(emailAddresses, into: self.emailAddresses) {
                $1.isEmpty ? nil : $1 as NSString
            }
        }

        if let postalAddresses = fields.postalAddresses {
            self.postalAddresses = merge(postalAddresses, into: self.postalAddresses) { stored, supplied in
                let address = stored?.mutableCopy() as? CNMutablePostalAddress ?? CNMutablePostalAddress()
                for field in ContactFields.postalFields {
                    if let text = supplied[field.key] { address[keyPath: field.path] = text }
                }
                return address
            }
        }

        if let birthday = fields.birthday { self.birthday = birthday }
    }

    /// The one rule for every labelled field: an entry addresses the first
    /// existing value carrying its label. `update` receives that value (nil
    /// when nothing carries the label) and returns its replacement, or nil to
    /// remove it. Values the entries do not address are never touched.
    private func merge<Input, T>(
        _ entries: [String: Input],
        into existing: [CNLabeledValue<T>],
        update: (T?, Input) -> T?
    ) -> [CNLabeledValue<T>] {
        var merged = existing
        for (key, input) in entries {
            let label = CNContactLabel.from(string: key)
            let index = merged.firstIndex { $0.label == label }
            if let value = update(index.map { merged[$0].value }, input) {
                if let index {
                    merged[index] = merged[index].settingValue(value)
                } else {
                    merged.append(CNLabeledValue(label: label, value: value))
                }
            } else if let index {
                merged.remove(at: index)
            }
        }
        return merged
    }
}
