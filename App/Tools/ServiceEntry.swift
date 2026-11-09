/// What the tool gate and the on/off switches need to know about one
/// service. How it looks lives in `ServicePresentation`; what it needs from
/// macOS, in its own `permission`.
struct ServiceEntry {
    let service: any Service
    /// What the menu, tool errors, and the listener endpoint file call it.
    let name: String
    /// A persisted UserDefaults key; it must never change.
    let enabledKey: String
    let defaultEnabled: Bool
    /// Location is the one service the menu and Settings treat apart: its
    /// switch also governs recording and the iCloud row.
    let isLocation: Bool

    init(service: any Service, name: String, enabledKey: String, defaultEnabled: Bool, isLocation: Bool = false) {
        self.service = service
        self.name = name
        self.enabledKey = enabledKey
        self.defaultEnabled = defaultEnabled
        self.isLocation = isLocation
    }

    var id: String { Self.id(of: service) }

    /// The one place a service's ID is derived. Nothing persists it; it only
    /// has to agree between the toggles and the tool gate.
    static func id(of service: any Service) -> String {
        id(of: type(of: service))
    }

    static func id(of type: any Service.Type) -> String {
        String(describing: type)
    }
}
