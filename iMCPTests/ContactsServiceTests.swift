import Contacts
import AppKit
import Combine
import SwiftUI
import XCTest
@testable import iMCP

/// Company cards used to vanish from contacts_search, and because the limit
/// was applied before they were dropped, they also shortened the results.
final class ContactCardTests: XCTestCase {
    private func json(_ card: ContactCard?) throws -> [String: Any] {
        let data = try JSONEncoder().encode(try XCTUnwrap(card))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testOrganizationCardIsReturnedWithItsIdentifier() throws {
        let contact = CNMutableContact()
        contact.contactType = .organization
        contact.organizationName = "Acme Dental"
        contact.phoneNumbers = [CNLabeledValue(label: CNLabelWork, value: CNPhoneNumber(stringValue: "555-0100"))]

        let object = try json(ContactCard(contact))
        XCTAssertEqual(object["@type"] as? String, "Organization")
        XCTAssertEqual(object["name"] as? String, "Acme Dental")
        XCTAssertEqual(object["@id"] as? String, contact.identifier)
    }

    func testPersonCardIsUnchanged() throws {
        let contact = CNMutableContact()
        contact.givenName = "Ada"

        let object = try json(ContactCard(contact))
        XCTAssertEqual(object["@type"] as? String, "Person")
        XCTAssertEqual(object["givenName"] as? String, "Ada")
    }
}

final class ContactPopulateTests: XCTestCase {
    private func address(street: String, city: String) -> CNMutablePostalAddress {
        let address = CNMutablePostalAddress()
        address.street = street
        address.city = city
        address.state = "CA"
        address.postalCode = "94110"
        address.country = "USA"
        address.subLocality = "Mission"
        return address
    }

    private func phone(_ label: String, _ number: String) -> CNLabeledValue<CNPhoneNumber> {
        CNLabeledValue(label: label, value: CNPhoneNumber(stringValue: number))
    }

    func testPostalAddressKeepsTheFieldsThatWereNotSent() throws {
        let contact = CNMutableContact()
        contact.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: address(street: "1 Main St", city: "SF"))]
        let identifier = contact.postalAddresses[0].identifier

        contact.populate(
            from: try ContactFields.update(["postalAddresses": .object(["home": .object(["city": .string("Oakland")])])]
            )
        )

        XCTAssertEqual(contact.postalAddresses.count, 1)
        let updated = contact.postalAddresses[0]
        XCTAssertEqual(updated.label, CNLabelHome)
        XCTAssertEqual(updated.identifier, identifier)
        XCTAssertEqual(updated.value.city, "Oakland")
        XCTAssertEqual(updated.value.street, "1 Main St")
        XCTAssertEqual(updated.value.state, "CA")
        XCTAssertEqual(updated.value.postalCode, "94110")
        XCTAssertEqual(updated.value.country, "USA")
        XCTAssertEqual(updated.value.subLocality, "Mission")
    }

    func testPostalAddressUpdateLeavesTheOtherAddressesAlone() throws {
        let contact = CNMutableContact()
        contact.postalAddresses = [
            CNLabeledValue(label: CNLabelHome, value: address(street: "1 Main St", city: "SF")),
            CNLabeledValue(label: CNLabelHome, value: address(street: "2 Lake Rd", city: "Tahoe")),
            CNLabeledValue(label: CNLabelWork, value: address(street: "3 Market St", city: "SF")),
        ]

        contact.populate(
            from: try ContactFields.update(["postalAddresses": .object(["home": .object(["city": .string("Oakland")])])]
            )
        )

        XCTAssertEqual(contact.postalAddresses.map(\.value.street), ["1 Main St", "2 Lake Rd", "3 Market St"])
        XCTAssertEqual(contact.postalAddresses.map(\.value.city), ["Oakland", "Tahoe", "SF"])
    }

    func testPhoneUpdateReplacesOnlyTheFirstValueWithThatLabel() throws {
        let contact = CNMutableContact()
        contact.phoneNumbers = [
            phone(CNLabelHome, "555-0001"), phone(CNLabelPhoneNumberMobile, "555-0002"), phone(CNLabelHome, "555-0003"),
        ]
        let identifier = contact.phoneNumbers[0].identifier

        contact.populate(from: try ContactFields.update(["phoneNumbers": .object(["home": .string("555-0009")])]))

        XCTAssertEqual(contact.phoneNumbers.map(\.value.stringValue), ["555-0009", "555-0002", "555-0003"])
        XCTAssertEqual(contact.phoneNumbers[0].identifier, identifier)
    }

    func testUnknownLabelIsAppended() throws {
        let contact = CNMutableContact()
        contact.phoneNumbers = [phone(CNLabelHome, "555-0001")]

        contact.populate(from: try ContactFields.update(["phoneNumbers": .object(["work": .string("555-0009")])]))

        XCTAssertEqual(contact.phoneNumbers.map(\.label), [CNLabelHome, CNLabelWork])
        XCTAssertEqual(contact.phoneNumbers.map(\.value.stringValue), ["555-0001", "555-0009"])
    }

    func testEmptyStringRemovesOnlyTheFirstValueWithThatLabel() throws {
        let contact = CNMutableContact()
        contact.emailAddresses = [
            CNLabeledValue(label: CNLabelHome, value: "a@example.com"),
            CNLabeledValue(label: CNLabelHome, value: "b@example.com"),
            CNLabeledValue(label: CNLabelWork, value: "c@example.com"),
        ]

        contact.populate(
            from: try ContactFields.update(["emailAddresses": .object(["home": .string(""), "school": .string("")])])
        )

        XCTAssertEqual(contact.emailAddresses.map { $0.value as String }, ["b@example.com", "c@example.com"])
    }

    /// Decision 6: a wrong-typed field used to be skipped while the call
    /// reported success; now it throws before any contact is touched, and the
    /// error names the field.
    func testWronglyTypedEntriesThrowNamingTheField() {
        let cases: [([String: Value], String)] = [
            (["phoneNumbers": .object(["home": .int(5)])], "phoneNumbers.home must be a string"),
            (["postalAddresses": .object(["home": .string("nowhere")])], "postalAddresses.home must be an object"),
            (
                ["postalAddresses": .object(["home": .object(["city": .int(5)])])],
                "postalAddresses.home.city must be a string"
            ),
            (["emailAddresses": .array([])], "emailAddresses must be an object"),
            (["givenName": .int(5)], "givenName must be a string"),
            (["jobTitle": .bool(true)], "jobTitle must be a string"),
            (["birthday": .object(["day": .double(15.5), "month": .int(3)])], "birthday.day must be a whole number"),
            (["birthday": .object(["month": .int(3)])], "birthday needs a day and a month"),
            // The schema documented these bounds, and day 40 still reached Contacts.
            (["birthday": .object(["day": .int(40), "month": .int(3)])], "birthday.day must be between 1 and 31"),
            (["birthday": .object(["day": .int(1), "month": .int(13)])], "birthday.month must be between 1 and 12"),
            (["birthday": .object(["day": .int(0), "month": .int(3)])], "birthday.day must be between 1 and 31"),
        ]
        for (arguments, message) in cases {
            XCTAssertThrowsError(try ContactFields.update(arguments), "\(arguments)") { error in
                XCTAssertEqual((error as? ToolInputError)?.message, message)
            }
        }
    }

    /// `day: 15.0` used to drop the whole birthday; a whole number reads the
    /// same however the client encodes it, like every other argument.
    func testABirthdayAcceptsWholeNumbersSentAsDoubles() throws {
        let contact = CNMutableContact()
        contact.populate(
            from: try ContactFields.update([
                "birthday": .object(["day": .double(15.0), "month": .int(3), "year": .double(1990)])
            ])
        )
        XCTAssertEqual(contact.birthday, DateComponents(year: 1990, month: 3, day: 15))
    }

    /// A JSON null entry is not sent, like a null argument.
    func testANullLabelledEntryChangesNothing() throws {
        let contact = CNMutableContact()
        contact.phoneNumbers = [phone(CNLabelHome, "555-0001")]

        contact.populate(from: try ContactFields.update(["phoneNumbers": .object(["home": .null])]))

        XCTAssertEqual(contact.phoneNumbers.map(\.value.stringValue), ["555-0001"])
    }

    func testOmittedPropertiesAreUntouched() throws {
        let contact = CNMutableContact()
        contact.givenName = "Ada"
        contact.phoneNumbers = [phone(CNLabelHome, "555-0001")]
        contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "a@example.com")]
        contact.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: address(street: "1 Main St", city: "SF"))]

        contact.populate(from: try ContactFields.update(["jobTitle": .string("Engineer")]))

        XCTAssertEqual(contact.givenName, "Ada")
        XCTAssertEqual(contact.jobTitle, "Engineer")
        XCTAssertEqual(contact.phoneNumbers.count, 1)
        XCTAssertEqual(contact.emailAddresses.count, 1)
        XCTAssertEqual(contact.postalAddresses.count, 1)
    }

    /// contacts_create runs the same function on an empty contact.
    func testFreshContactGetsEveryLabelledValue() throws {
        let contact = CNMutableContact()

        contact.populate(
            from: try ContactFields.update([
                "givenName": .string("Ada"),
                "phoneNumbers": .object(["mobile": .string("555-0001")]),
                "emailAddresses": .object(["work": .string("ada@example.com")]),
                "postalAddresses": .object(["home": .object(["street": .string("1 Main St"), "city": .string("SF")])]),
            ])
        )

        XCTAssertEqual(contact.givenName, "Ada")
        XCTAssertEqual(contact.phoneNumbers.map(\.label), [CNLabelPhoneNumberMobile])
        XCTAssertEqual(contact.phoneNumbers.map(\.value.stringValue), ["555-0001"])
        XCTAssertEqual(contact.emailAddresses.map(\.label), [CNLabelWork])
        XCTAssertEqual(contact.emailAddresses.map { $0.value as String }, ["ada@example.com"])
        XCTAssertEqual(contact.postalAddresses.map(\.label), [CNLabelHome])
        XCTAssertEqual(contact.postalAddresses.map(\.value.street), ["1 Main St"])
        XCTAssertEqual(contact.postalAddresses.map(\.value.city), ["SF"])
    }
}

final class ContactsUpdateIdentifierTests: XCTestCase {
    func testContactsUpdateAcceptsSearchAtId() {
        XCTAssertEqual(try ContactsService.identifier(["@id": .string("search-id")]), "search-id")
        XCTAssertEqual(try ContactsService.identifier(["identifier": .string("legacy-id")]), "legacy-id")
        XCTAssertThrowsError(try ContactsService.identifier(["identifier": .string("")]))
    }
}
