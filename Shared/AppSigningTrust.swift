import Foundation
import Security

/// Whether a process is the signed iMCP app, which decides whether the CLI
/// believes the listener-endpoint file that names it.
enum AppSigningTrust {
    /// Info.plist `CFBundleIdentifier` is not consulted.
    static func designatedRequirement(forTeam teamIdentifier: String) -> String {
        "identifier \"\(WireContract.appBundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// Team identifier this binary is itself signed with, or `nil` when it is
    /// unsigned or ad-hoc signed.
    static let ownTeamIdentifier: String? = {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
            let staticCode
        else { return nil }
        var info: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &info
            ) == errSecSuccess,
            let info = info as? [String: Any]
        else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// The requirement the app process must satisfy, pinned to the team that
    /// signed this binary. `nil` when this binary carries no team.
    ///
    /// The team is read from our own signature rather than written in here. The
    /// CLI ships inside the app bundle, so the two always carry the same team,
    /// while a literal goes wrong silently the moment a build is signed with any
    /// other identity -- a fork, or a local install re-signed with a personal
    /// Apple Development certificate, which `Scripts/install-local.sh` accepts.
    /// Nothing fails loudly when that happens: the app is simply never trusted,
    /// the loopback handoff is skipped on every start, and each launch pays for
    /// Bonjour discovery instead. That fallback costs about a second with the app
    /// already advertising and up to a 30-second browse timeout plus a 5-second
    /// retry sleep per cycle when it is not, which is what a client sees at login.
    static var releaseDesignatedRequirement: String? {
        ownTeamIdentifier.map(designatedRequirement(forTeam:))
    }

    /// A same-user process can rewrite the endpoint file with its own live pid;
    /// it cannot satisfy the designated requirement without the signing identity.
    static func isSignedIMCPProcess(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(
            nil,
            [kSecGuestAttributePid: pid] as CFDictionary,
            SecCSFlags(),
            &code
        )
        guard status == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
            let staticCode
        else { return false }
        if satisfiesRequirement(staticCode, compiledReleaseRequirement) {
            return true
        }
        return acceptsDebugIMCPSigning(staticCode)
    }

    private static let compiledReleaseRequirement = releaseDesignatedRequirement.flatMap(compiledRequirement)

    private static func compiledRequirement(_ text: String) -> SecRequirement? {
        var requirement: SecRequirement?
        guard
            SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement)
                == errSecSuccess
        else { return nil }
        return requirement
    }

    /// Checks the bundle the process was launched from rather than its running
    /// pages. `SecCodeCheckValidity` additionally re-hashes loaded code, and a
    /// Debug build fails it with `errSecCSStaticCodeChanged` because Xcode runs
    /// the app out of `iMCP.debug.dylib` rather than the sealed main executable.
    /// That took the loopback fast path out for every local install. Dynamic
    /// validity is not the trust boundary here in any case: the connection is
    /// authenticated by the signed auth preamble, and this check only decides
    /// whether the endpoint file is worth believing.
    private static func satisfiesRequirement(
        _ staticCode: SecStaticCode,
        _ requirement: SecRequirement?
    ) -> Bool {
        guard let requirement else { return false }
        return SecStaticCodeCheckValidity(staticCode, SecCSFlags(), requirement) == errSecSuccess
    }

    #if DEBUG
        /// Ad-hoc Xcode Debug (`CODE_SIGN_IDENTITY = "-"`) keeps loopback for the
        /// test host. Signing info is the code identifier, not Info.plist
        /// `CFBundleIdentifier`.
        private static func acceptsDebugIMCPSigning(_ staticCode: SecStaticCode) -> Bool {
            // An ad-hoc signature needs no secret to make. It is accepted only
            // for builds with no team identity (CI signs ad hoc); a team-signed
            // build verifies the app against its own team instead.
            guard ownTeamIdentifier == nil else { return false }
            return isAdHocIMCP(staticCode)
        }

        private static func isAdHocIMCP(_ staticCode: SecStaticCode) -> Bool {
            var info: CFDictionary?
            guard
                SecCodeCopySigningInformation(
                    staticCode,
                    SecCSFlags(rawValue: kSecCSSigningInformation),
                    &info
                ) == errSecSuccess,
                let info = info as? [String: Any],
                let identifier = info[kSecCodeInfoIdentifier as String] as? String,
                identifier == WireContract.appBundleIdentifier
            else { return false }
            let flags: UInt32
            if let value = info[kSecCodeInfoFlags as String] as? UInt32 {
                flags = value
            } else if let value = info[kSecCodeInfoFlags as String] as? Int {
                flags = UInt32(value)
            } else if let value = info[kSecCodeInfoFlags as String] as? NSNumber {
                flags = value.uint32Value
            } else {
                return false
            }
            // `kSecCodeSignatureAdhoc` (CSCommon.h) is 0x0002; Swift does not import the C enum.
            return (flags & 0x0002) != 0
        }
    #else
        private static func acceptsDebugIMCPSigning(_ staticCode: SecStaticCode) -> Bool {
            _ = staticCode
            return false
        }
    #endif
}
