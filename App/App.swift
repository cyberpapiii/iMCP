import MenuBarExtraAccess
import SwiftUI

@main
struct App: SwiftUI.App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PreferenceKey.showMenuBarExtra) private var showMenuBarExtra = PreferenceKey.showMenuBarExtraDefault
    @State private var isMenuPresented = false
    private let environment: AppEnvironment

    init() {
        EarlyExitCommands.runIfRequested()
        environment = .shared
    }

    var body: some Scene {
        @Bindable var appDelegate = appDelegate

        // Without the binding, removing the item from the menu bar quits the
        // app and takes the server down with it.
        MenuBarExtra(isInserted: $appDelegate.isMenuBarExtraInserted) {
            ContentView(
                serverController: environment.serverController,
                appStatus: environment.appStatus,
                isMenuPresented: $isMenuPresented,
                showConnectClient: environment.connectClient.show,
                showLocationWindow: environment.locationWindow.show,
                showSettings: showSettings,
                guidance: environment.guidance
            )
        } label: {
            MenuBarLabel(serverController: environment.serverController, appStatus: environment.appStatus)
        }
        .menuBarExtraStyle(.window)
        .menuBarExtraAccess(isPresented: $isMenuPresented)
        .onChange(of: showMenuBarExtra) { _, showMenuBarExtra in
            appDelegate.isMenuBarExtraInserted = showMenuBarExtra
        }
        .onChange(of: appDelegate.shouldOpenSettings, initial: true) { _, shouldOpenSettings in
            guard shouldOpenSettings else { return }
            appDelegate.shouldOpenSettings = false
            showSettings()
        }

        // A plain window, not a `Settings` scene: Settings windows get no
        // toolbar, and the page title and Back and Forward live in one.
        Window("iMCP Settings", id: Self.settingsWindowID) {
            SettingsView(
                serverController: environment.serverController,
                appStatus: environment.appStatus,
                iCloud: environment.iCloud,
                pairedClients: environment.pairedClients,
                locationData: environment.locationData,
                showConnectClient: environment.connectClient.show,
                showLocationWindow: environment.locationWindow.show,
                guidance: environment.guidance,
                isMenuBarExtraInserted: appDelegate.isMenuBarExtraInserted
            )
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…", action: showSettings)
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    static let settingsWindowID = "settings"

    /// Opening the window alone does nothing visible when this menu-bar-only
    /// app is not active: the window opens, or already is open, behind
    /// whatever the user is working in.
    private func showSettings() {
        environment.activation.activateApp()
        openWindow(id: Self.settingsWindowID)
    }
}

@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
    var shouldOpenSettings = false
    /// Whether the item is in the menu bar now. Kept apart from the saved
    /// preference: macOS can remove the item itself, and that must not
    /// overwrite what the user chose.
    var isMenuBarExtraInserted = AppDelegate.menuBarExtraPreference()

    static func menuBarExtraPreference() -> Bool {
        UserDefaults.standard.object(forKey: PreferenceKey.showMenuBarExtra) as? Bool
            ?? PreferenceKey.showMenuBarExtraDefault
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // With the item hidden there is nothing else to click.
        if !Self.menuBarExtraPreference() {
            shouldOpenSettings = true
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Opening the app again is the only way back in when the item is gone.
        // With the item present this stays quiet: macOS also sends a reopen
        // when the always-on agent relaunches the app, and a Settings window
        // on every relaunch is noise.
        if !isMenuBarExtraInserted {
            shouldOpenSettings = true
        }
        return false
    }

    /// A `Window` scene makes SwiftUI quit the app when its last window
    /// closes. The server lives in the menu bar, not in a window, so closing
    /// Settings or an approval prompt must leave it running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Apple rotates the session cookies on every Find My call and the
        // write is debounced by up to a minute. Quitting without it can
        // leave the next launch replaying a dead jar. Whichever of these
        // finishes first ends the app; the reply does not return.
        Task {
            await AppEnvironment.shared.iCloud.flushCookies()
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
