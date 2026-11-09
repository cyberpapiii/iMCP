import Foundation
import OSLog

/// `iMCP.app/Contents/MacOS/iMCP --always-on on|off`
///
/// Registering the always-on agent goes through `SMAppService`, which only the
/// app may call for its own bundle, so a script that reinstalls or repairs the
/// install has no way to put the setting back once it is lost. This flag gives
/// it one: the app applies the setting and exits before any window or menu bar
/// item exists.
enum AlwaysOnCommandLine {
    enum Request: Equatable {
        case enable
        case disable

        var isEnabled: Bool { self == .enable }
    }

    static let flag = "--always-on"

    /// Returns the request the arguments ask for, or nil when they ask for
    /// nothing, name an unknown value, or leave the flag without one.
    static func request(from arguments: [String]) -> Request? {
        var value: String?
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == flag {
                value = arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
            } else if argument.hasPrefix("\(flag)=") {
                value = String(argument.dropFirst(flag.count + 1))
            }
            index += 1
        }

        switch value?.lowercased() {
        case "on", "true", "yes", "1": return .enable
        case "off", "false", "no", "0": return .disable
        default: return nil
        }
    }

    /// Applies the requested setting and exits. Does nothing and returns when
    /// the arguments carry no request, which is every ordinary launch.
    static func runIfRequested(_ arguments: [String] = CommandLine.arguments) {
        guard arguments.contains(where: { $0 == flag || $0.hasPrefix("\(flag)=") }) else {
            return
        }
        guard let request = request(from: arguments) else {
            FileHandle.standardError.write(Data("Usage: iMCP \(flag) on|off\n".utf8))
            exit(2)
        }

        do {
            try AlwaysOnService.setEnabled(request.isEnabled)
            print("Always-on agent \(request.isEnabled ? "registered" : "unregistered")")
            exit(0)
        } catch {
            FileHandle.standardError.write(
                Data("Could not change the always-on agent: \(error.localizedDescription)\n".utf8)
            )
            exit(1)
        }
    }
}
