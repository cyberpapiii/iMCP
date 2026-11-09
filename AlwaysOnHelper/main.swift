import AppKit
import Darwin
import OSLog

private func currentExecutableURL() -> URL {
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    if proc_pidpath(getpid(), &path, UInt32(path.count)) > 0 {
        return URL(fileURLWithPath: String(cString: path))
    }
    return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
}

/// The helper runs from `iMCP.app/Contents/MacOS`, so the app it keeps alive
/// is the bundle it sits in.
private func containingApplicationURL(of executableURL: URL) -> URL {
    var containingURL = executableURL.deletingLastPathComponent()
    while containingURL.pathExtension != "app", containingURL.path != "/" {
        containingURL.deleteLastPathComponent()
    }
    return containingURL
}

private let applicationURL = containingApplicationURL(of: currentExecutableURL())
private let containingBundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier
private let logger = Logger(subsystem: containingBundleIdentifier ?? "iMCPAlwaysOn", category: "always-on")

private final class AppKeeper {
    private let applicationURL: URL
    private let appBundleIdentifier: String
    private var processSource: DispatchSourceProcess?

    init(applicationURL: URL, appBundleIdentifier: String) {
        self.applicationURL = applicationURL
        self.appBundleIdentifier = appBundleIdentifier
    }

    func run() {
        watchOrLaunchApp()
        RunLoop.main.run()
    }

    private func watchOrLaunchApp() {
        // The exit event can arrive while LaunchServices still lists the dead
        // process, and a process source for a pid that is gone traps.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: appBundleIdentifier)
            .first { !$0.isTerminated && kill($0.processIdentifier, 0) == 0 }
        if let running {
            watch(running)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        // A relaunch right after a force quit can fail while LaunchServices
        // still lists the dead process. Prompting would show the user an
        // "is not open anymore" alert for every attempt; the KeepAlive
        // restart below retries silently instead.
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { application, error in
            if let error {
                logger.error("Failed to relaunch iMCP: \(error.localizedDescription, privacy: .public)")
                // Nothing is being watched now. launchd restarts the helper
                // (KeepAlive), and the fresh start retries the launch.
                exit(1)
            } else if let application {
                self.watch(application)
            }
        }
    }

    private func watch(_ application: NSRunningApplication) {
        processSource?.cancel()
        let source = DispatchSource.makeProcessSource(
            identifier: application.processIdentifier,
            eventMask: .exit,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.processSource = nil
            self?.watchOrLaunchApp()
        }
        processSource = source
        source.resume()
    }
}

guard let appBundleIdentifier = containingBundleIdentifier else {
    logger.error("No app bundle contains \(applicationURL.path, privacy: .public)")
    // launchd restarts the helper (KeepAlive); a broken install stays broken
    // until it is reinstalled, at one attempt per throttle interval.
    exit(1)
}
AppKeeper(applicationURL: applicationURL, appBundleIdentifier: appBundleIdentifier).run()
