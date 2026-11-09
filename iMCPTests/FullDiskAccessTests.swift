import XCTest

@testable import iMCP

final class FullDiskAccessTests: XCTestCase {
    func testFullDiskAccessProbeSkipsMissingFiles() {
        let errors: [String: Int32] = ["/gone": ENOENT, "/readable": 0]
        XCTAssertTrue(
            FullDiskAccess.isGranted(probing: ["/gone", "/readable"]) { errors[$0] ?? ENOENT }
        )
    }

    func testFullDiskAccessProbeTreatsDenialAsNotGranted() {
        let errors: [String: Int32] = ["/gone": ENOENT, "/protected": EPERM, "/readable": 0]
        XCTAssertFalse(
            FullDiskAccess.isGranted(probing: ["/gone", "/protected", "/readable"]) {
                errors[$0] ?? ENOENT
            }
        )
    }

    func testFullDiskAccessProbeIsNotGrantedWhenNothingExists() {
        XCTAssertFalse(FullDiskAccess.isGranted(probing: ["/gone"]) { _ in ENOENT })
    }
}
