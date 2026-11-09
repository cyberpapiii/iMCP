import Combine
import Foundation

/// Owns whether iMCP serves at all and which services it serves. Every change
/// to either, whoever makes it, reaches the listener, the tool gate, and the
/// services in the order it was made; views only read and write.
@MainActor
final class ServerController: ObservableObject {
    let networkManager: ServerNetworkManager
    private let entries: [ServiceEntry]
    private let defaults: UserDefaults
    /// The tail of the chain that applies changes in order.
    private var pendingWork: Task<Void, Never>?
    private var appliedServiceIDs: Set<String> = []

    /// The menu's master switch.
    @Published var isServerEnabled: Bool {
        didSet {
            guard isServerEnabled != oldValue else { return }
            defaults.set(isServerEnabled, forKey: PreferenceKey.serverEnabled)
            applyServerEnabled()
        }
    }

    /// True while iMCP is on and no listener could be made, so no client can
    /// connect until it is switched off and on again.
    @Published private(set) var isListenerFailed = false

    /// Service metadata is immutable for the controller's lifetime. Cache it so SwiftUI
    /// body evaluation only reads the live values instead of rebuilding every switch.
    private(set) lazy var serviceSwitches: [ServiceSwitch] = {
        entries.map { entry in
            let enabled = enabledAccessors(for: entry)
            return ServiceSwitch(entry: entry, isEnabled: enabled.get, setEnabled: enabled.set)
        }
    }()

    var isLocationEnabled: Bool {
        serviceSwitches.contains { $0.entry.isLocation && $0.isEnabled }
    }

    /// `entries` are the services whose lifecycle follows their switches.
    init(networkManager: ServerNetworkManager, entries: [ServiceEntry], defaults: UserDefaults = .standard) {
        self.networkManager = networkManager
        self.entries = entries
        self.defaults = defaults
        isServerEnabled =
            defaults.object(forKey: PreferenceKey.serverEnabled) as? Bool ?? PreferenceKey.serverEnabledDefault
        // The enabled services are in place before the listener can accept.
        applyServiceEnablement()
        applyServerEnabled()
        Task { [weak self, networkManager] in
            for await state in networkManager.listenerStates {
                guard let self else { return }
                self.isListenerFailed = state == .failed
            }
        }
    }

    /// Returns once every change made so far has been applied.
    func settle() async {
        await pendingWork?.value
    }

    private func enabledAccessors(
        for entry: ServiceEntry
    ) -> (get: () -> Bool, set: (Bool) -> Void) {
        let key = entry.enabledKey
        let defaultValue = entry.defaultEnabled
        let defaults = defaults
        return (
            get: {
                Self.storedEnabledValue(in: defaults, forKey: key, default: defaultValue)
            },
            set: { [weak self] newValue in
                guard newValue != Self.storedEnabledValue(in: defaults, forKey: key, default: defaultValue)
                else { return }
                // Write before notifying, so a view that re-reads as soon as
                // it is told sees the new value.
                defaults.set(newValue, forKey: key)
                self?.objectWillChange.send()
                self?.applyServiceEnablement()
            }
        )
    }

    private static func storedEnabledValue(
        in defaults: UserDefaults,
        forKey key: String,
        default defaultValue: Bool
    ) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }

    private func applyServerEnabled() {
        let enabled = isServerEnabled
        enqueue { [networkManager] in
            await networkManager.setEnabled(enabled)
        }
    }

    /// The snapshot is taken now, at the write, and applied in its turn.
    private func applyServiceEnablement() {
        let enabled = Set(serviceSwitches.filter(\.isEnabled).map(\.id))
        enqueue { [weak self] in
            guard let self, enabled != self.appliedServiceIDs else { return }
            let previous = self.appliedServiceIDs
            self.appliedServiceIDs = enabled
            await self.networkManager.updateEnabledServices(enabled)
            for entry in self.entries {
                let id = entry.id
                if enabled.contains(id) != previous.contains(id) {
                    await entry.service.enablementDidChange(enabled: enabled.contains(id))
                }
            }
        }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = pendingWork
        pendingWork = Task {
            await previous?.value
            await work()
        }
    }
}
