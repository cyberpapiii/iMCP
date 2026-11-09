import Foundation

/// `iMCP.app/Contents/MacOS/iMCP --doctor-facts`
///
/// Prints the Keychain services, bundle id, and paths this build uses, one `key=value`
/// per line, and exits before any window, listener, or Keychain access exists.
/// `Scripts/doctor.sh` checks these values instead of keeping its own copies.
enum DoctorFactsCommandLine {
    static let flag = "--doctor-facts"

    static func runIfRequested(_ arguments: [String] = CommandLine.arguments) {
        guard arguments.contains(flag) else { return }
        print(report())
        exit(0)
    }

    /// Every generic-password service this build reads or writes, including
    /// the ones a Debug build only migrates from.
    static var keychainServices: [String] {
        var services = [PairedClientStorage.keychainService]
        #if DEBUG
            services.append(PairedClientStorage.debugFileAdoptedService)
        #endif
        services.append(ICloudCredentialStorage.keychainService)
        #if DEBUG
            services.append(ICloudCredentialStorage.debugKeychainService)
        #endif
        services += [
            LocalStorageKeyStorage.databaseKeyService,
            LocalStorageKeyStorage.identitySecretService,
            FindMyPeopleBootstrap.stateItem.service,
            FindMyPeopleBootstrap.installationItem.service,
        ]
        return services
    }

    static func report() -> String {
        #if DEBUG
            var lines = ["configuration=debug"]
        #else
            var lines = ["configuration=release"]
        #endif
        lines += keychainServices.map { "keychain-service=\($0)" }
        lines.append("bundle-id=\(Bundle.main.bundleIdentifier ?? "")")
        lines.append("app-support-dir=\(WireContract.appSupportDirectory().path)")
        lines.append("endpoint-file=\(ListenerEndpointFile.fileURL().path)")
        return lines.joined(separator: "\n")
    }
}
