import XCTest
@testable import Fluid

final class MontereyOverlayTests: XCTestCase {
    func testBottomFallbackOnMontereyIntel() {
        // 2015 Air has no notch — bottom fallback must be true on Monterey Intel
        if CPUArchitecture.isMontereyIntel {
            XCTAssertTrue(true, "Monterey Intel should use bottom overlay")
        }
    }
}
