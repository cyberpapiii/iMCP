import AppKit

/// How a window of this app comes to the front. iMCP is a menu bar app, so
/// nothing brings it forward on its own: it has to activate before ordering
/// a window front, or the window opens behind whatever the user was working
/// in.
struct WindowActivation: Sendable {
    let activateApp: @MainActor @Sendable () -> Void

    static let app = WindowActivation { NSApp.activate(ignoringOtherApps: true) }
    /// For a host that must not take focus, such as the test host.
    static let inert = WindowActivation {}

    @MainActor
    func bringToFront(_ window: NSWindow?) {
        activateApp()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The one window of its kind: made the first time it is shown, brought to
/// the front every time after, and optionally let go when it closes.
@MainActor
final class SingleWindowPresenter<Controller: NSWindowController> {
    private let make: () -> Controller
    private let activation: WindowActivation
    private(set) var controller: Controller?

    init(activation: WindowActivation, make: @escaping () -> Controller) {
        self.activation = activation
        self.make = make
    }

    func show() {
        let shown = controller ?? make()
        controller = shown
        activation.activateApp()
        // Makes the window key and orders it front.
        shown.showWindow(nil)
    }

    /// For a window that must not outlive its close: the next `show` makes a
    /// fresh one.
    func release(_ closed: Controller) {
        if controller === closed { controller = nil }
    }
}
