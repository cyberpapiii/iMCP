# Plan 041: `contacts_update` changes only the values it is asked to change

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 8165d29..HEAD -- App/Extensions/Contacts+Extensions.swift App/Services/Contacts.swift iMCPTests/AppModelTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition. (Plans 038, 039 and 042 edit other
> parts of `App/Services/Contacts.swift`; a diff confined to the `limit`
> parsing, the `annotations:` blocks, or the `NSError` throws in `activate()`
> is expected and is not a mismatch. Line numbers below will have shifted;
> locate code by symbol.)

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW — one private helper and three call sites in one file, covered by new pure tests; no Contacts store access changes
- **Depends on**: plans/037-isolate-tests-from-real-state.md
- **Category**: bug
- **Planned at**: commit `8165d29`, 2026-10-12

## Why this matters

`contacts_update` tells clients "Send only the properties that change; omitted
properties keep their current values", and then destroys data the client never
mentioned. Sending `{"postalAddresses": {"home": {"city": "Oakland"}}}` replaces
the home address with one that has only a city: street, state, postcode and
country are gone. Sending one `home` phone number deletes **every** phone
number labelled home and appends a single new one; the same happens for email
addresses and postal addresses. The write goes straight to the user's real
address book (and from there to iCloud), there is no undo, and no test covers
any of it. After this plan a labelled entry changes exactly one existing value
or adds one, an address keeps the fields the client did not send, the tool
description states that rule, and tests pin it.

A second, smaller defect in the same handler is fixed along the way:
updating a company card saves correctly but returns `null` to the client.

## Current state

### Files

- `App/Extensions/Contacts+Extensions.swift` (120 lines) — `CNContactLabel`
  (label-name mapping) and `CNMutableContact.populate(from:)`, the single
  function that applies tool arguments to a contact. Contains both defects.
- `App/Services/Contacts.swift` — `ContactsService`; the `contacts_update` and
  `contacts_create` tool handlers both call `populate(from:)`. Also defines
  `ContactCard`.
- `iMCPTests/AppModelTests.swift` — existing app test file; already imports
  `Contacts` and hosts `ContactCardTests` (the exemplar). New tests go here.

### Defect 1 — a supplied postal address replaces the stored one wholesale

```swift
// App/Extensions/Contacts+Extensions.swift:53-86
        if case let .object(postalAddresses) = arguments["postalAddresses"] {
            var merged = self.postalAddresses
            for entry in postalAddresses {
                guard case let .object(addressData) = entry.value else { continue }
                let label = CNContactLabel.from(string: entry.key)
                merged.removeAll { $0.label == label }

                let postalAddress = CNMutablePostalAddress()

                if case let .string(street) = addressData["street"] {
                    postalAddress.street = street
                }
                if case let .string(city) = addressData["city"] {
                    postalAddress.city = city
                }
                if case let .string(state) = addressData["state"] {
                    postalAddress.state = state
                }
                if case let .string(postalCode) = addressData["postalCode"] {
                    postalAddress.postalCode = postalCode
                }
                if case let .string(country) = addressData["country"] {
                    postalAddress.country = country
                }

                merged.append(
                    CNLabeledValue(
                        label: label,
                        value: postalAddress
                    )
                )
            }
            self.postalAddresses = merged
        }
```

`CNMutablePostalAddress()` starts empty, so every field the client did not
send is lost. It also loses fields this tool cannot even express
(`subLocality`, `subAdministrativeArea`, `isoCountryCode`).

### Defect 2 — `removeAll` deletes every value sharing the label

Same file, line 58 above (postal addresses) and the shared helper used for
phone numbers (line 39) and email addresses (line 45):

```swift
// App/Extensions/Contacts+Extensions.swift:104-119
    private func mergeLabeledValues<T>(
        existing: [CNLabeledValue<T>],
        from entries: [String: Value],
        makeValue: (String) -> T
    ) -> [CNLabeledValue<T>] {
        var merged = existing
        for entry in entries {
            guard case let .string(value) = entry.value else { continue }
            let label = CNContactLabel.from(string: entry.key)
            merged.removeAll { $0.label == label }
            if !value.isEmpty {
                merged.append(CNLabeledValue(label: label, value: makeValue(value)))
            }
        }
        return merged
    }
```

A contact with two `home` numbers loses both when the client sends one. The
replacement is also appended at the end with a new identifier, so the Contacts
store sees a delete plus an add rather than an edit.

The call sites:

```swift
// App/Extensions/Contacts+Extensions.swift:38-51
        if case let .object(phoneNumbers) = arguments["phoneNumbers"] {
            self.phoneNumbers = mergeLabeledValues(existing: self.phoneNumbers, from: phoneNumbers) {
                CNPhoneNumber(stringValue: $0)
            }
        }

        if case let .object(emailAddresses) = arguments["emailAddresses"] {
            self.emailAddresses = mergeLabeledValues(
                existing: self.emailAddresses,
                from: emailAddresses
            ) {
                $0 as NSString
            }
        }
```

There is no URL handling anywhere in this file or in the tool schema; only
phone numbers, email addresses and postal addresses are labelled fields here.

### Defect 3 — updating a company card returns `null`

```swift
// App/Services/Contacts.swift:287-296  (contacts_update handler)
            updatedContact.populate(from: arguments)

            let saveRequest = CNSaveRequest()
            saveRequest.update(updatedContact)

            try await self.runContactStore {
                try self.contactStore.execute(saveRequest)
            }

            return Person(updatedContact)
```

`Person(_:)` is failable and rejects company cards. The type that handles both
already exists a few lines down in the same file, and its comment says search
results keep `@id` precisely so they can be passed to `contacts_update`:

```swift
// App/Services/Contacts.swift:337-353
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
```

So a client that searches, gets an organization, and updates it has the write
succeed and receives `null`. For a person, `ContactCard` encodes exactly what
`Person` encodes (pinned by `ContactCardTests.testPersonCardIsUnchanged`).

### The tool description that promises otherwise

```swift
// App/Services/Contacts.swift:246-249
        Tool(
            name: "contacts_update",
            description:
                "Update an existing contact and return it. Send only the properties that change; omitted properties keep their current values.",
```

### `contacts_create` uses the same function and needs no change

```swift
// App/Services/Contacts.swift:316-317
            let newContact = CNMutableContact()
            newContact.populate(from: arguments)
```

On a fresh contact every labelled array is empty, so the new rule reduces to
"append". A test pins that (Step 1, `testFreshContactGetsEveryLabelledValue`).

### The merge contract (this is the specification for Step 2)

One rule for all three labelled fields (`phoneNumbers`, `emailAddresses`,
`postalAddresses`). For each `label: value` entry the client sends:

1. The entry addresses **the first existing value carrying that label**
   (after `CNContactLabel.from(string:)` mapping). No other value is touched,
   moved, or removed — including other values with the same label.
2. If such a value exists it is changed **in place** (same position, same
   `CNLabeledValue.identifier`):
   - phone / email: the value is replaced by the supplied string;
   - postal address: only the supplied fields (`street`, `city`, `state`,
     `postalCode`, `country`) are overwritten; every other field keeps its
     stored value.
3. If no value carries the label, a new one is appended.
4. An **empty string** for a phone or email removes that one addressed value
   (and does nothing if no value carries the label). This keeps the removal
   affordance commit `40d4091` introduced, narrowed from "all with the label"
   to "one". Postal addresses are never removed by this tool.
5. A wrongly typed entry (a number where a string is expected, a string where
   an address object is expected) is skipped and changes nothing. This is
   today's behaviour; keep it.

### Conventions that apply

- `swift format`: 4-space indent, 120-column limit; lint is strict.
- Swift 6 strict concurrency, warnings are errors. A file-scope `let` holding
  key paths is not `Sendable` and fails the build; keep the key-path table a
  local constant inside `populate(from:)` as shown in Step 2.
- `Value` is `MCP.Value`, re-exported app-wide by `App/Models/Value.swift`
  (`@_exported import enum MCP.Value`). Tests build argument dictionaries with
  literals such as `["@id": .string("x")]` — see
  `iMCPTests/CallToolDispatchTests.swift:146`.
- Tests are plain `XCTest`. Test files are **not** in a synchronized Xcode
  group: a new test file silently never runs unless four entries are added to
  `iMCP.xcodeproj/project.pbxproj`. This plan adds a class to an existing
  file, so no project edit is needed.
- `CNMutableContact`, `CNLabeledValue` and `CNMutablePostalAddress` are plain
  value objects. Creating and mutating them touches no Contacts store and
  needs no privacy permission, so the tests are pure.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` | exit 0 |
| New tests only | `Scripts/test.sh --only iMCPTests/ContactPopulateTests` | all pass |
| Contact tests | `Scripts/test.sh --only iMCPTests/ContactPopulateTests --only iMCPTests/ContactCardTests` | all pass |
| App tests | `Scripts/test.sh --app-only` | all pass |
| All tests | `Scripts/test.sh` | all pass |
| Format | `swift format -i -r .` | exit 0 |
| Lint | `swift format lint --strict --recursive .` | exit 0 |

`-quiet` suppresses the success banner; success is exit code 0. `--only SPEC`
passes `-only-testing:SPEC` to the app suite and is repeatable.

**Never** run `xcodebuild test -scheme iMCP` directly: the always-on watchdog
relaunches the installed app and breaks the test host. **Never**
`launchctl bootout` the always-on agent. `Scripts/test.sh` handles both.

## Scope

**In scope** (the only files you should modify):
- `App/Extensions/Contacts+Extensions.swift`
- `App/Services/Contacts.swift` — two edits only: the `contacts_update`
  description string and the handler's `return` line
- `iMCPTests/AppModelTests.swift` — add one test class
- `plans/README.md` — status row for 041 only

**Out of scope** (do NOT touch, even though they look related):
- `annotations:` on any contacts tool (`destructiveHint` and friends) — plan 039.
- The `limit` parsing in `contacts_search`, and validation of `birthday`
  day/month ranges or integer-typed arguments — plan 038.
- The five-line `NSError(domain: "ContactsService", …)` throws in
  `activate()` — plan 042.
- `contactProperties` / `postalAddressSchema` (the input schema). The argument
  shape does not change; only behaviour does.
- `CNContactLabel.from(string:)`. Adding more label names (`other`, `iPhone`,
  `main`, `school`) is a feature, not this bug.
- The scalar fields (`givenName`, `familyName`, `organizationName`,
  `jobTitle`) and `birthday` in `populate(from:)`. They already overwrite only
  when supplied.
- The `contacts_create` handler. It needs no change.
- `iMCP.xcodeproj/project.pbxproj`. No new file is created.
- Adding any test that reads or writes the real Contacts store.

## Git workflow

- Start from an up-to-date `main` (`git fetch origin && git switch -c advisor/041-contacts-update-data-loss origin/main`).
- Conventional commits, matching the log, e.g.
  `fix: bring Settings forward from the menu; stay quiet on relaunch`.
  Suggested: one commit,
  `fix(contacts): update one labelled value in place instead of replacing all`.
- Do NOT push or open a PR unless the operator says so. `origin`
  (`cyberpapiii/iMCP`) is the only writable remote; `upstream`
  (`mattt/iMCP`) must never receive pushes or PRs.

## Steps

### Step 1: Add the tests first, and watch the right ones fail

In `iMCPTests/AppModelTests.swift`, directly after the closing brace of
`final class ContactCardTests` (and before `final class LocalISO8601Tests`),
add this class. `import Contacts` is already at the top of the file.

```swift
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

    func testPostalAddressKeepsTheFieldsThatWereNotSent() {
        let contact = CNMutableContact()
        contact.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: address(street: "1 Main St", city: "SF"))]
        let identifier = contact.postalAddresses[0].identifier

        contact.populate(from: ["postalAddresses": .object(["home": .object(["city": .string("Oakland")])])])

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

    func testPostalAddressUpdateLeavesTheOtherAddressesAlone() {
        let contact = CNMutableContact()
        contact.postalAddresses = [
            CNLabeledValue(label: CNLabelHome, value: address(street: "1 Main St", city: "SF")),
            CNLabeledValue(label: CNLabelHome, value: address(street: "2 Lake Rd", city: "Tahoe")),
            CNLabeledValue(label: CNLabelWork, value: address(street: "3 Market St", city: "SF")),
        ]

        contact.populate(from: ["postalAddresses": .object(["home": .object(["city": .string("Oakland")])])])

        XCTAssertEqual(contact.postalAddresses.map(\.value.street), ["1 Main St", "2 Lake Rd", "3 Market St"])
        XCTAssertEqual(contact.postalAddresses.map(\.value.city), ["Oakland", "Tahoe", "SF"])
    }

    func testPhoneUpdateReplacesOnlyTheFirstValueWithThatLabel() {
        let contact = CNMutableContact()
        contact.phoneNumbers = [
            phone(CNLabelHome, "555-0001"), phone(CNLabelPhoneNumberMobile, "555-0002"), phone(CNLabelHome, "555-0003"),
        ]
        let identifier = contact.phoneNumbers[0].identifier

        contact.populate(from: ["phoneNumbers": .object(["home": .string("555-0009")])])

        XCTAssertEqual(contact.phoneNumbers.map(\.value.stringValue), ["555-0009", "555-0002", "555-0003"])
        XCTAssertEqual(contact.phoneNumbers[0].identifier, identifier)
    }

    func testUnknownLabelIsAppended() {
        let contact = CNMutableContact()
        contact.phoneNumbers = [phone(CNLabelHome, "555-0001")]

        contact.populate(from: ["phoneNumbers": .object(["work": .string("555-0009")])])

        XCTAssertEqual(contact.phoneNumbers.map(\.label), [CNLabelHome, CNLabelWork])
        XCTAssertEqual(contact.phoneNumbers.map(\.value.stringValue), ["555-0001", "555-0009"])
    }

    func testEmptyStringRemovesOnlyTheFirstValueWithThatLabel() {
        let contact = CNMutableContact()
        contact.emailAddresses = [
            CNLabeledValue(label: CNLabelHome, value: "a@example.com"),
            CNLabeledValue(label: CNLabelHome, value: "b@example.com"),
            CNLabeledValue(label: CNLabelWork, value: "c@example.com"),
        ]

        contact.populate(from: ["emailAddresses": .object(["home": .string(""), "school": .string("")])])

        XCTAssertEqual(contact.emailAddresses.map { $0.value as String }, ["b@example.com", "c@example.com"])
    }

    func testWronglyTypedEntriesChangeNothing() {
        let contact = CNMutableContact()
        contact.phoneNumbers = [phone(CNLabelHome, "555-0001")]
        contact.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: address(street: "1 Main St", city: "SF"))]

        contact.populate(from: [
            "phoneNumbers": .object(["home": .int(5)]),
            "postalAddresses": .object(["home": .string("nowhere")]),
        ])

        XCTAssertEqual(contact.phoneNumbers.map(\.value.stringValue), ["555-0001"])
        XCTAssertEqual(contact.postalAddresses.map(\.value.street), ["1 Main St"])
    }

    func testOmittedPropertiesAreUntouched() {
        let contact = CNMutableContact()
        contact.givenName = "Ada"
        contact.phoneNumbers = [phone(CNLabelHome, "555-0001")]
        contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "a@example.com")]
        contact.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: address(street: "1 Main St", city: "SF"))]

        contact.populate(from: ["jobTitle": .string("Engineer")])

        XCTAssertEqual(contact.givenName, "Ada")
        XCTAssertEqual(contact.jobTitle, "Engineer")
        XCTAssertEqual(contact.phoneNumbers.count, 1)
        XCTAssertEqual(contact.emailAddresses.count, 1)
        XCTAssertEqual(contact.postalAddresses.count, 1)
    }

    /// contacts_create runs the same function on an empty contact.
    func testFreshContactGetsEveryLabelledValue() {
        let contact = CNMutableContact()

        contact.populate(from: [
            "givenName": .string("Ada"),
            "phoneNumbers": .object(["mobile": .string("555-0001")]),
            "emailAddresses": .object(["work": .string("ada@example.com")]),
            "postalAddresses": .object(["home": .object(["street": .string("1 Main St"), "city": .string("SF")])]),
        ])

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
```

Notes for writing these:

- `[String: Value]` iteration order is not defined. No test above sends two
  entries for the **same** field and then asserts their relative order; keep
  it that way if you add cases.
- If `swift format` wants the three-element `contact.phoneNumbers = [...]`
  literal on separate lines, let it; do not fight the formatter.

**Verify**: `Scripts/test.sh --only iMCPTests/ContactPopulateTests` → the run
**fails**, and exactly these four tests fail (they are the regression proof):

- `testPostalAddressKeepsTheFieldsThatWereNotSent`
- `testPostalAddressUpdateLeavesTheOtherAddressesAlone`
- `testPhoneUpdateReplacesOnlyTheFirstValueWithThatLabel`
- `testEmptyStringRemovesOnlyTheFirstValueWithThatLabel`

The other four pass. If the file does not compile, fix the test code, not the
source. If a different set fails, see STOP conditions.

### Step 2: Replace both merge implementations with one in-place helper

All edits in `App/Extensions/Contacts+Extensions.swift`.

**2a.** Delete the private `mergeLabeledValues(existing:from:makeValue:)`
function (lines 104-119) and put this in its place:

```swift
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
```

`settingValue(_:)` is the Contacts API that returns the same labelled value
(same label, same identifier) with a new value; it is what makes this an edit
rather than a delete plus an add.

**2b.** Replace the three labelled-field blocks in `populate(from:)` — the
`phoneNumbers` block, the `emailAddresses` block and the whole
`postalAddresses` block (lines 38-86) — with:

```swift
        if case let .object(phoneNumbers) = arguments["phoneNumbers"] {
            self.phoneNumbers = merge(phoneNumbers.compactMapValues(\.stringValue), into: self.phoneNumbers) {
                $1.isEmpty ? nil : CNPhoneNumber(stringValue: $1)
            }
        }

        if case let .object(emailAddresses) = arguments["emailAddresses"] {
            self.emailAddresses = merge(emailAddresses.compactMapValues(\.stringValue), into: self.emailAddresses) {
                $1.isEmpty ? nil : $1 as NSString
            }
        }

        if case let .object(postalAddresses) = arguments["postalAddresses"] {
            let fields: [(String, ReferenceWritableKeyPath<CNMutablePostalAddress, String>)] = [
                ("street", \.street), ("city", \.city), ("state", \.state),
                ("postalCode", \.postalCode), ("country", \.country),
            ]
            self.postalAddresses = merge(postalAddresses.compactMapValues(\.objectValue), into: self.postalAddresses) {
                stored, supplied in
                let address = stored?.mutableCopy() as? CNMutablePostalAddress ?? CNMutablePostalAddress()
                for (key, path) in fields {
                    if case let .string(text) = supplied[key] { address[keyPath: path] = text }
                }
                return address
            }
        }
```

Why this shape (do not "improve" it):

- `compactMapValues(\.stringValue)` / `(\.objectValue)` drop wrongly typed
  entries before the helper sees them, which is contract rule 5. Both
  accessors are already used in this repo's tests
  (`iMCPTests/CallToolDispatchTests.swift:92,117`).
  `testWronglyTypedEntriesChangeNothing` is the gate: if it fails because
  `stringValue` coerces a number into a string, replace `\.stringValue` with
  `{ if case let .string(text) = $0 { text } else { nil } }` at both call
  sites and re-run.
- `stored?.mutableCopy()` starts from the stored address, so unsent fields
  (including ones this tool cannot express) survive. The postal closure never
  returns nil, so addresses are never removed (contract rule 4).
- `fields` is a local `let` on purpose: key paths are not `Sendable`, and a
  file-scope constant fails the Swift 6 build.
- If the compiler cannot infer a closure's type, annotate the closure
  parameters (for example `{ (_: CNPhoneNumber?, number: String) in … }`);
  do not change the helper's signature.

**2c.** Update the doc comment above `populate(from:)` so it states the rule.
Replace the existing two lines with:

```swift
    /// Applies whichever fields the arguments dictionary carries. Missing or
    /// wrongly typed keys are skipped, so existing values survive untouched.
    /// A labelled entry (phone, email, postal address) changes the first
    /// existing value with that label in place, or adds one; see `merge`.
```

**Verify**:
```console
grep -c "removeAll" App/Extensions/Contacts+Extensions.swift
grep -c "mergeLabeledValues" App/Extensions/Contacts+Extensions.swift
grep -c "settingValue" App/Extensions/Contacts+Extensions.swift
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
Scripts/test.sh --only iMCPTests/ContactPopulateTests ; echo "exit=$?"
```
→ `0`, `0`, `1`, `exit=0`, `exit=0` with all 8 `ContactPopulateTests` passing.

### Step 3: Return the updated card for company contacts too

In `App/Services/Contacts.swift`, in the `contacts_update` handler only,
change the last line

```swift
            return Person(updatedContact)
```

to

```swift
            return ContactCard(updatedContact)
```

Do **not** change the identical-looking `return Person(newContact)` in the
`contacts_create` handler.

**Verify**:
```console
grep -c "return ContactCard(updatedContact)" App/Services/Contacts.swift
grep -c "return Person(updatedContact)" App/Services/Contacts.swift
grep -c "return Person(newContact)" App/Services/Contacts.swift
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
```
→ `1`, `0`, `1`, `exit=0`.

### Step 4: Make the tool description state the contract

In `App/Services/Contacts.swift`, replace the `contacts_update` description
string with exactly:

```swift
                "Update an existing contact and return it. Send only what changes: omitted properties, and omitted fields of a postal address, keep their current values. Each phoneNumbers, emailAddresses, or postalAddresses entry changes the first existing value with that label, or adds one if none has it; other values are left alone. An empty string removes that one phone number or email address.",
```

Leave the `contacts_create` description and every schema unchanged.

**Verify**:
```console
grep -c "changes the first existing value with that label" App/Services/Contacts.swift
grep -c "omitted properties keep their current values" App/Services/Contacts.swift
```
→ `1`, `0`.

### Step 5: Run the full gate

```console
swift format -i -r .
swift format lint --strict --recursive . ; echo "exit=$?"
xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build ; echo "exit=$?"
Scripts/test.sh ; echo "exit=$?"
git status --short
```

**Verify**: three `exit=0`; `git status --short` lists only
`App/Extensions/Contacts+Extensions.swift`, `App/Services/Contacts.swift`,
`iMCPTests/AppModelTests.swift` (and `plans/README.md` once you update it).
If `swift format -i` touched any other file, revert that file
(`git checkout -- <file>`) and re-run the lint.

Commit, then update the 041 row in `plans/README.md`.

## Test plan

- **New**: `ContactPopulateTests` in `iMCPTests/AppModelTests.swift`, 8 tests
  (full code in Step 1):
  - regression, defect 1: `testPostalAddressKeepsTheFieldsThatWereNotSent`
  - regression, defect 2: `testPostalAddressUpdateLeavesTheOtherAddressesAlone`,
    `testPhoneUpdateReplacesOnlyTheFirstValueWithThatLabel`,
    `testEmptyStringRemovesOnlyTheFirstValueWithThatLabel`
  - contract edges: `testUnknownLabelIsAppended`,
    `testWronglyTypedEntriesChangeNothing`, `testOmittedPropertiesAreUntouched`
  - `contacts_create` path: `testFreshContactGetsEveryLabelledValue`
- **Structural pattern**: `ContactCardTests` in the same file
  (`iMCPTests/AppModelTests.swift:642-668`) — builds a `CNMutableContact` in
  memory and asserts on it; no store, no permission.
- **Existing coverage relied on for Step 3**: `ContactCardTests` already pins
  that `ContactCard` encodes a person identically to `Person` and an
  organization with its `@id`.
- **Not automated** (needs the real Contacts store and a privacy grant, so it
  must not be a unit test): an end-to-end `contacts_update` call. Do not
  attempt it; say in your report that it was not exercised.
- Verification: `Scripts/test.sh` → all pass, including the 8 new tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -c "removeAll" App/Extensions/Contacts+Extensions.swift` → `0`
- [ ] `grep -c "mergeLabeledValues" App/Extensions/Contacts+Extensions.swift` → `0`
- [ ] `grep -c "settingValue" App/Extensions/Contacts+Extensions.swift` → `1`
- [ ] `wc -l < App/Extensions/Contacts+Extensions.swift` is less than `120` (the file got shorter)
- [ ] `grep -c "return ContactCard(updatedContact)" App/Services/Contacts.swift` → `1`
- [ ] `grep -c "changes the first existing value with that label" App/Services/Contacts.swift` → `1`
- [ ] `grep -c "final class ContactPopulateTests" iMCPTests/AppModelTests.swift` → `1`
- [ ] `xcodebuild -quiet -scheme iMCP -configuration Debug -destination "platform=macOS" build` exits 0
- [ ] `Scripts/test.sh` exits 0; the 8 `ContactPopulateTests` exist and pass
- [ ] `swift format lint --strict --recursive .` exits 0
- [ ] `git diff --stat main -- iMCP.xcodeproj` is empty
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row for 041 updated

## STOP conditions

Stop and report back (do not improvise) if:

- The code in `App/Extensions/Contacts+Extensions.swift` does not match the
  "Current state" excerpts (for example `mergeLabeledValues` is already gone,
  or `populate(from:)` has moved) — someone else changed the merge logic.
- In Step 1 the set of failing tests is not exactly the four listed. A listed
  test passing before the fix means the defect is not where this plan says; an
  unlisted test failing means an assumption about current behaviour is wrong.
- After Step 2, `testPostalAddressKeepsTheFieldsThatWereNotSent` or
  `testPhoneUpdateReplacesOnlyTheFirstValueWithThatLabel` fails **only** on
  its `identifier` assertion. That means `settingValue(_:)` does not preserve
  the identifier on this SDK. Do not rebuild the labelled value another way;
  report it, with the two identifiers printed.
- The helper cannot be made to compile without adding a generic constraint
  beyond what the compiler infers, a new type, or a file-scope constant.
- Step 3 fails to compile because the handler's return type no longer unifies
  (another plan changed the handler's result type).
- Any step appears to need an edit to `iMCP.xcodeproj/project.pbxproj`, the
  input schemas, `CNContactLabel`, or a tool's `annotations:`.
- A step's verification fails twice after a reasonable fix attempt.
- You are tempted to verify by calling `contacts_update` against the real
  address book. Do not; it writes to the user's contacts and iCloud.

## Maintenance notes

For the human/agent who owns this code after the change lands:

- **Behaviour change clients can observe**: sending a label that matches
  several stored values used to collapse them into one; it now edits the first
  and leaves the rest. A client that relied on the collapse to de-duplicate
  will no longer get it. There is deliberately no "replace all" mode.
- **Reviewer focus**: (1) the helper has three outcomes — edit in place,
  append, remove — and "skip" happens before it, in `compactMapValues`; a
  wrongly typed entry must never reach the remove branch. (2) the postal
  closure starts from `stored?.mutableCopy()`, never from an empty address
  when one exists. (3) only `contacts_update`'s return line changed.
- **Plan 054 (write verbs)** specifies "partial-update semantics identical to
  plan 041's contacts contract". The contract is the five numbered rules in
  "Current state"; `merge(_:into:update:)` is the reference implementation.
- **Known and left alone**:
  - `{"postalAddresses": {"home": {}}}` on a contact with no home address
    still appends an empty address, as it does today. Not data loss; fold a
    guard into plan 038's argument validation if it matters.
  - Label matching is exact after `CNContactLabel.from(string:)`, which maps
    only `mobile`, `work`, `home`. A stored `iPhone`- or `Other`-labelled
    value cannot be addressed, so `mobile` appends next to an `iPhone` number
    rather than editing it. Extending the label map is a small follow-up.
  - When two new labels are sent for one field in a single call, their
    relative order follows dictionary iteration and is not stable.
  - `birthday` needs integer `day` and `month`; range and type validation
    belongs to plan 038.
  - `contacts_create` still returns `Person(newContact)`. A new contact is
    always a person card, so it cannot be nil today; switch it to
    `ContactCard` only if create ever sets `contactType`.
- **Install**: do not run `Scripts/install-local.sh run` as part of this
  plan. The operator installs when they choose to.
