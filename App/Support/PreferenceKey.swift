/// UserDefaults keys for the app's own preferences, each with the value it
/// reads as before the user sets it. Each service's switch keeps its key on
/// its `ServiceEntry`. These are persisted: renaming one loses what the user
/// chose.
enum PreferenceKey {
    /// The menu's master switch: whether agents may use this Mac at all.
    static let serverEnabled = "isEnabled"
    static let serverEnabledDefault = true
    static let showMenuBarExtra = "showMenuBarExtra"
    static let showMenuBarExtraDefault = true
    /// How the Location window draws the track: by time, or as a heat map.
    static let locationMapMode = "locationMapMode"
    /// How much history the Location window shows: a `LocationPeriod`.
    static let locationPeriod = "locationPeriod"
}
