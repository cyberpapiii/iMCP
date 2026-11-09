/// The launch arguments that do one job and exit, so a script can register
/// the always-on agent, read the iCloud snapshot, or list the build's
/// Keychain services and paths without a person opening Settings.
enum EarlyExitCommands {
    /// Must run before any of the app's objects exist: a property initializer
    /// would start the location sampler, and a status check that calls Apple
    /// can get the stored session rejected. Returns on an ordinary launch.
    static func runIfRequested() {
        AlwaysOnCommandLine.runIfRequested()
        ICloudStatusCommandLine.runIfRequested()
        DoctorFactsCommandLine.runIfRequested()
    }
}
