/// Every service the app offers, in menu order.
enum ServiceRegistry {
    static let entries: [ServiceEntry] = {
        var items: [ServiceEntry] = [
            ServiceEntry(
                service: BrowserHistoryService.shared,
                name: "Browser History",
                enabledKey: "browserHistoryEnabled",
                defaultEnabled: false
            ),
            ServiceEntry(
                service: CalendarService.shared,
                name: "Calendar",
                enabledKey: "calendarEnabled",
                defaultEnabled: false
            ),
            ServiceEntry(
                service: CallHistoryService.shared,
                name: "Call History",
                enabledKey: "callHistoryEnabled",
                defaultEnabled: false
            ),
            ServiceEntry(
                service: CaptureService.shared,
                name: "Capture",
                enabledKey: "captureEnabled",
                defaultEnabled: false
            ),
            ServiceEntry(
                service: ContactsService.shared,
                name: "Contacts",
                enabledKey: "contactsEnabled",
                defaultEnabled: false
            ),
            location,
            ServiceEntry(service: MapsService.shared, name: "Maps", enabledKey: "mapsEnabled", defaultEnabled: true),
            ServiceEntry(
                service: MessageService.shared,
                name: "Messages",
                enabledKey: "messagesEnabled",
                defaultEnabled: false
            ),
            ServiceEntry(
                service: NotesService.shared,
                name: "Notes",
                enabledKey: "notesEnabled",
                defaultEnabled: false
            ),
            ServiceEntry(
                service: NotificationsService.shared,
                name: "Notifications",
                enabledKey: "notificationsEnabled",
                defaultEnabled: false
            ),
            ServiceEntry(
                service: PhotoService.shared,
                name: "Photos",
                enabledKey: "photosEnabled",
                defaultEnabled: false
            ),
            ServiceEntry(
                service: RemindersService.shared,
                name: "Reminders",
                enabledKey: "remindersEnabled",
                defaultEnabled: false
            ),
            ServiceEntry(
                service: ScreenTimeService.shared,
                name: "Screen Time",
                enabledKey: "screenTimeEnabled",
                defaultEnabled: false
            ),
            ServiceEntry(
                service: ShortcutsService.shared,
                name: "Shortcuts",
                enabledKey: "shortcutsEnabled",
                defaultEnabled: false
            ),
            ServiceEntry(
                service: UtilitiesService.shared,
                name: "Utilities",
                enabledKey: "utilitiesEnabled",
                defaultEnabled: true
            ),
        ]
        #if WEATHERKIT_AVAILABLE
            items.append(weather)
        #endif
        return items
    }()

    static let location = ServiceEntry(
        service: LocationEnvironment.service,
        name: "Location",
        enabledKey: "locationEnabled",
        defaultEnabled: true,
        isLocation: true
    )

    /// Listed only where WeatherKit is available.
    static let weather = ServiceEntry(
        service: WeatherService.shared,
        name: "Weather",
        enabledKey: "weatherEnabled",
        defaultEnabled: false
    )
}
