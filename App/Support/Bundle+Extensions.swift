import Foundation

extension Bundle {
    var name: String? {
        infoDictionary?["CFBundleName"] as? String
    }

    var shortVersionString: String? {
        infoDictionary?["CFBundleShortVersionString"] as? String
    }

    var copyright: String? {
        infoDictionary?["NSHumanReadableCopyright"] as? String
    }

    var imcpServerPath: String {
        bundleURL.appendingPathComponent("Contents/MacOS/imcp-server").path
    }
}
