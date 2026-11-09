import AppKit
import EventKit
import Ontology

extension EKEventAvailability {
    static let names = NamedCases<EKEventAvailability>([
        ("busy", .busy),
        ("free", .free),
        ("tentative", .tentative),
        ("unavailable", .unavailable),
    ])
}

extension EKEventStatus {
    static let names = NamedCases<EKEventStatus>([
        ("none", .none),
        ("tentative", .tentative),
        ("confirmed", .confirmed),
        ("canceled", .canceled),
    ])
}

extension EKAlarmProximity {
    /// The cases a proximity alarm can take; `.none` is no proximity alarm.
    static let names = NamedCases<EKAlarmProximity>([
        ("enter", .enter),
        ("leave", .leave),
    ])

    /// What a proximity alarm fires on when the caller does not say.
    static let defaultForAlarm = EKAlarmProximity.enter
}

extension EKReminderPriority {
    static let names = NamedCases<EKReminderPriority>([
        ("none", .none),
        ("low", .low),
        ("medium", .medium),
        ("high", .high),
    ])
}

extension EKCalendar {
    var serviceListValue: Value {
        .object([
            "title": .string(title),
            "source": .string(source.title),
            "color": .string(color.accessibilityName),
            "isEditable": .bool(allowsContentModifications),
            "isSubscribed": .bool(isSubscribed),
        ])
    }
}
