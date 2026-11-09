import AppKit

/// Takes the owner to where a missing permission is granted. The one place
/// that opens System Settings or the iCloud sign-in window for a permission,
/// and the one grant flow the menu toggle and every Grant button share.
@MainActor
struct GuidanceRouter {
    /// Records every grant, so it reaches every surface at once.
    let status: AppStatusModel
    let showICloudSignIn: @MainActor () -> Void

    func open(_ guidance: ServicePermission.Guidance) {
        switch guidance {
        case .systemSettings(let url):
            NSWorkspace.shared.open(url)
        case .iCloudSignIn:
            showICloudSignIn()
        }
    }

    func openFullDiskAccessSettings() {
        open(.systemSettings(ServicePermission.fullDiskAccessPaneURL))
    }

    /// Switches the service on at once and, unless its access is already
    /// known to be granted, asks for it. A refusal switches it back off,
    /// except where the permission keeps the toggle on to show its badge.
    /// The returned task finishes when the request has.
    @discardableResult
    func switchOn(_ serviceSwitch: ServiceSwitch) -> Task<Void, Never>? {
        let knownGranted = status.status.serviceAccess[serviceSwitch.id] == true
        serviceSwitch.isEnabled = true
        guard !knownGranted else { return nil }
        return Task { [status] in
            let request = await status.requestAccess(for: serviceSwitch)
            if !request.succeeded, !serviceSwitch.permission.keepsToggleOnAfterFailedActivation {
                serviceSwitch.isEnabled = false
            }
        }
    }

    /// Asks for the permission and, if it is still missing afterwards,
    /// opens where it is granted.
    func grantAccess(to serviceSwitch: ServiceSwitch) async {
        let request = await status.requestAccess(for: serviceSwitch)
        if !request.isActivated, let guidance = serviceSwitch.permission.guidance {
            open(guidance)
        }
    }
}
