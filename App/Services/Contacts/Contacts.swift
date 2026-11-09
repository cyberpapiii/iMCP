import Contacts
import Foundation
import OSLog
import Ontology

private let log = Logger.service("contacts")

private let contactKeys =
    [
        CNContactTypeKey,
        CNContactGivenNameKey,
        CNContactFamilyNameKey,
        CNContactBirthdayKey,
        CNContactOrganizationNameKey,
        CNContactJobTitleKey,
        CNContactPhoneNumbersKey,
        CNContactEmailAddressesKey,
        CNContactInstantMessageAddressesKey,
        CNContactSocialProfilesKey,
        CNContactUrlAddressesKey,
        CNContactPostalAddressesKey,
        CNContactRelationsKey,
    ] as [CNKeyDescriptor]

final class ContactsService: Service {
    private let contactStore = CNContactStore()

    static let shared = ContactsService()

    var permission: ServicePermission { .contacts }

    private func runContactStore<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await Task(priority: .utility) {
            try operation()
        }.value
    }

    var isActivated: Bool {
        get async {
            let status = CNContactStore.authorizationStatus(for: .contacts)
            return status == .authorized
        }
    }

    func activate() async throws {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return }
        if status == .notDetermined, try await contactStore.requestAccess(for: .contacts) { return }
        log.error("Contacts access not granted")
        throw permission.deniedError
    }

    private static let name = ToolArgument.text(
        "name",
        description: "Name to search for, matched against the contact's full name",
        trimmed: true
    )
    private static let phone = ToolArgument.text("phone", description: "Phone number to search for", trimmed: true)
    private static let email = ToolArgument.text(
        "email",
        description: "Email address to search for; case is ignored",
        trimmed: true
    )
    private static let limit = ToolArgument.integer(
        "limit",
        description: "Maximum contacts to return",
        default: 20,
        in: 1 ... 100
    )
    /// Also read under `@id`, which the schema does not document: it is the
    /// key contacts_search results carry the identifier under.
    static let identifier = ToolArgument<String>(
        properties: [
            (
                "identifier",
                .string(description: "Identifier of the contact to update: the @id value contacts_search returns")
            )
        ]
    ) { arguments in
        for key in ["@id", "identifier"] {
            if case let .string(identifier) = arguments[key], !identifier.isEmpty {
                return identifier
            }
        }
        throw ToolInputError("Valid contact identifier required")
    }

    var tools: [Tool] {
        Tool(
            name: "contacts_me",
            description:
                "Get contact information about the user, including name, phone number, email, birthday, relations, address, online presence, and occupation. Any addresses returned are the stored home and work addresses on the contact card, not where the user or anyone else currently is. Always run this tool when the user asks a question that requires personal information about themselves.",
            arguments: [],
            annotations: .init(
                title: "Who Am I?",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            let contact = try await self.runContactStore {
                try self.contactStore.unifiedMeContactWithKeys(toFetch: contactKeys)
            }
            return Person(contact)
        }

        Tool(
            name: "contacts_search",
            description:
                "Search contacts by name, phone number, and/or email. At least one is required, and a contact must match every one supplied.",
            arguments: [Self.name, Self.phone, Self.email, Self.limit],
            annotations: .init(
                title: "Search Contacts",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            var predicates: [NSPredicate] = []

            if let name = try Self.name(arguments) {
                predicates.append(CNContact.predicateForContacts(matchingName: name))
            }

            if let phone = try Self.phone(arguments) {
                predicates.append(CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: phone)))
            }

            if let email = try Self.email(arguments) {
                predicates.append(CNContact.predicateForContacts(matchingEmailAddress: email.lowercased()))
            }

            guard !predicates.isEmpty else {
                throw ToolInputError("At least one valid search parameter is required")
            }

            let finalPredicate =
                predicates.count == 1
                ? predicates[0]
                : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)

            let limit = try Self.limit(arguments)

            let contacts = try await self.runContactStore {
                try self.contactStore.unifiedContacts(
                    matching: finalPredicate,
                    keysToFetch: contactKeys
                )
            }

            // Filter before limiting, so skipped cards never use up the limit.
            return Array(contacts.lazy.compactMap(ContactCard.init).prefix(limit))
        }

        Tool(
            name: "contacts_update",
            description:
                "Update an existing contact and return it. Send only what changes: omitted properties, and omitted fields of a postal address, keep their current values. Each phoneNumbers, emailAddresses, or postalAddresses entry changes the first existing value with that label, or adds one if none has it; other values are left alone. An empty string removes that one phone number or email address.",
            arguments: [Self.identifier, ContactFields.update],
            annotations: .init(
                title: "Update Contact",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let identifier = try Self.identifier(arguments)
            let fields = try ContactFields.update(arguments)

            let predicate = CNContact.predicateForContacts(withIdentifiers: [identifier])
            let contact =
                try await self.runContactStore {
                    try self.contactStore.unifiedContacts(matching: predicate, keysToFetch: contactKeys)
                }
                .first?
                .mutableCopy() as? CNMutableContact

            guard let updatedContact = contact else {
                throw ToolInputError("Contact not found with identifier: \(identifier)")
            }

            updatedContact.populate(from: fields)

            let saveRequest = CNSaveRequest()
            saveRequest.update(updatedContact)

            try await self.runContactStore {
                try self.contactStore.execute(saveRequest)
            }

            return ContactCard(updatedContact)
        }

        Tool(
            name: "contacts_create",
            description:
                "Create a contact in the user's address book and return it. A given name is required.",
            arguments: [ContactFields.create],
            annotations: .init(
                title: "Create Contact",
                readOnlyHint: false,
                destructiveHint: false,
                openWorldHint: false
            )
        ) { arguments in
            let newContact = CNMutableContact()
            newContact.populate(from: try ContactFields.create(arguments))

            let saveRequest = CNSaveRequest()
            saveRequest.add(newContact, toContainerWithIdentifier: nil)

            try await self.runContactStore {
                try self.contactStore.execute(saveRequest)
            }

            return Person(newContact)
        }
    }
}

/// A contacts_search result. `Person(_:)` rejects company cards, which
/// silently dropped every business from search results, so organizations get
/// their own shape. The `@id` is kept on both so a result can be passed to
/// contacts_update.
enum ContactCard: Encodable {
    case person(Person)
    case organization(Organization, identifier: String)

    init?(_ contact: CNContact) {
        if let person = Person(contact) {
            self = .person(person)
        } else if let organization = Organization(contact) {
            self = .organization(organization, identifier: contact.identifier)
        } else {
            return nil
        }
    }

    private struct IdentifierKey: CodingKey {
        var stringValue: String { "@id" }
        var intValue: Int? { nil }
        init() {}
        init?(stringValue: String) { nil }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .person(let person):
            try person.encode(to: encoder)
        case .organization(let organization, let identifier):
            try organization.encode(to: encoder)
            var container = encoder.container(keyedBy: IdentifierKey.self)
            try container.encode(identifier, forKey: IdentifierKey())
        }
    }
}
