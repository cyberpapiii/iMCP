import EventKit
import Foundation
import os

/// Full access to one entity. A successful request counts as granted even
/// though EventKit can go on reporting denied until the app relaunches.
final class EventKitAccess {
    let entity: EventKitEntity
    let store: EKEventStore
    private let grantedByRequest = OSAllocatedUnfairLock(initialState: false)

    init(entity: EventKitEntity, store: EKEventStore) {
        self.entity = entity
        self.store = store
    }

    var isGranted: Bool {
        grantedByRequest.withLock { $0 } || EKEventStore.authorizationStatus(for: entity.type) == .fullAccess
    }

    func activate() async throws {
        if isGranted { return }
        let granted =
            switch entity.type {
            case .event: try await store.requestFullAccessToEvents()
            case .reminder: try await store.requestFullAccessToReminders()
            @unknown default: false
            }
        guard granted else {
            throw ServicePermission.eventKit(entity).deniedError
        }
        grantedByRequest.withLock { $0 = true }
    }
}

/// How a caller names a calendar or reminder list, and what it is told when
/// the name is wrong.
extension EventKitEntity {
    /// A container as error text names it.
    private var containerKind: String { type == .event ? "Calendar" : "Reminder list" }

    /// The tool that lists valid container names.
    var listTool: String { type == .event ? "calendars_list" : "reminders_lists" }

    /// The one writable calendar or list called `name`, ignoring case.
    func editableContainer(named name: String, in store: EKEventStore) throws -> EKCalendar {
        try requireSingleContainer(
            store.calendars(for: type).filter {
                $0.title.lowercased() == name.lowercased() && $0.allowsContentModifications
            },
            named: name
        )
    }

    /// A calendar or list name the caller got wrong is theirs to fix, so the
    /// error must reach them instead of the generic failure text. It echoes
    /// only the name they sent and points at the tool that lists the real ones.
    func requireSingleContainer<Match>(_ matches: [Match], named name: String) throws -> Match {
        guard matches.count == 1, let match = matches.first else {
            throw ToolInputError(
                matches.isEmpty
                    ? notFound(name)
                    : "\(containerKind) name is ambiguous: \(name). Rename one so each name is unique."
            )
        }
        return match
    }

    /// Narrows `items` to the names the caller asked for; no names means all
    /// of them. A name that matches nothing throws: EventKit does not document
    /// what an empty calendars array selects, so a typo must not reach it.
    func itemsMatchingRequestedNames<Item>(
        _ items: [Item],
        names: [String]?,
        title: (Item) -> String
    ) throws -> [Item] {
        guard let names, !names.isEmpty else { return items }
        var requested: Set<String> = []
        for name in names {
            guard items.contains(where: { title($0).lowercased() == name.lowercased() }) else {
                throw ToolInputError(notFound(name))
            }
            requested.insert(name.lowercased())
        }
        return items.filter { requested.contains(title($0).lowercased()) }
    }

    private func notFound(_ name: String) -> String {
        "\(containerKind) not found: \(name). Call \(listTool) for valid names."
    }
}

/// Runs `write`, which applies a call's fields to `item` and saves it. If it
/// throws, the item's unsaved changes are discarded before the error goes on:
/// both services keep one event store for their whole life, so an item left
/// dirty would be written by the next save that commits.
func discardingChangesOnFailure(to item: EKObject, _ write: () throws -> Void) throws {
    do {
        try write()
    } catch {
        item.reset()
        throw error
    }
}

/// 366 days. An alarm further out than that is a mistake, and the bound keeps
/// multiplication by 60 inside `Int`.
private let maxAlarmMinutes = 527_040

/// Seconds relative to the due or start date for an alarm `minutes` argument:
/// positive minutes fire before it, negative after.
func alarmRelativeOffset(minutes value: Value) throws -> TimeInterval {
    guard let minutes = value.wholeNumberValue,
        (-maxAlarmMinutes ... maxAlarmMinutes).contains(minutes)
    else {
        throw ToolInputError(
            "Alarm minutes must be a whole number between -\(maxAlarmMinutes) and \(maxAlarmMinutes)"
        )
    }
    return TimeInterval(-minutes * 60)
}
