import SwiftUI

/// How a service looks in the menu and Settings, keyed by service ID. Its
/// name is its entry's.
struct ServicePresentation {
    let iconName: String
    let color: Color

    static let table: [String: ServicePresentation] = [
        "BrowserHistoryService": .init(iconName: "safari.fill", color: .blue.mix(with: .cyan, by: 0.3)),
        "CalendarService": .init(iconName: "calendar", color: .red),
        "CallHistoryService": .init(iconName: "phone.fill", color: .green.mix(with: .black, by: 0.2)),
        "CaptureService": .init(iconName: "camera.on.rectangle.fill", color: .gray.mix(with: .black, by: 0.7)),
        "ContactsService": .init(iconName: "person.crop.square.filled.and.at.rectangle.fill", color: .brown),
        "LocationService": .init(iconName: "location.fill", color: .blue),
        "MapsService": .init(iconName: "mappin.and.ellipse", color: .purple),
        "MessageService": .init(iconName: "message.fill", color: .green),
        "NotesService": .init(iconName: "note.text", color: .yellow.mix(with: .orange, by: 0.4)),
        "NotificationsService": .init(iconName: "bell.badge.fill", color: .red.mix(with: .orange, by: 0.3)),
        "PhotoService": .init(iconName: "photo.on.rectangle.angled", color: .yellow),
        "RemindersService": .init(iconName: "list.bullet", color: .orange),
        "ScreenTimeService": .init(iconName: "hourglass", color: .indigo.mix(with: .blue, by: 0.4)),
        "ShortcutsService": .init(iconName: "square.2.layers.3d", color: .indigo),
        "UtilitiesService": .init(iconName: "wrench.and.screwdriver.fill", color: .teal),
        "WeatherService": .init(iconName: "cloud.sun.fill", color: .cyan),
    ]

    static func of(_ id: String) -> ServicePresentation {
        guard let presentation = table[id] else {
            preconditionFailure("\(id) has no ServicePresentation")
        }
        return presentation
    }
}
