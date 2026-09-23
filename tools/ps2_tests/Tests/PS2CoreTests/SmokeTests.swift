import XCTest
@testable import PS2Core

final class SmokeTests: XCTestCase {
    func testPackageBuilds() { XCTAssertNotNil(PS2Core.self) }
}
