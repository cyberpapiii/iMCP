import Foundation

/// The name to log for an error whose own words must not be shown. Foundation
/// hands a URLSession failure back as a bare `NSError` about as often as a
/// `URLError`, so the dynamic type alone would name the same network failure
/// two ways.
func errorTypeName(for error: Error) -> String {
    if (error as NSError).domain == NSURLErrorDomain {
        return "URLError"
    }
    return String(describing: type(of: error))
}
