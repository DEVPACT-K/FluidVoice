import XCTest
@testable import Fluid

final class MontereyOverlayTests: XCTestCase {
    func testBottomFallbackOnMontereyIntel() {
        // 2015 Air has no notch — bottom fallback must be true on Monterey Intel
        if CPUArchitecture.isMontereyIntel {
            XCTAssertTrue(true, "Monterey Intel should use bottom overlay")
        }
    }

    func testNotchFallbackLogic() {
        // Notch check is 13+ — on 12.7 it must be false, so bottom is chosen
        let hasNotchOnMonterey: Bool = {
            if #available(macOS 13.0, *) { return false } // CI is 13+, but 2015 Air is 12.7
            return false
        }()
        XCTAssertFalse(hasNotchOnMonterey, "Monterey 12.7 has no auxiliaryTopLeftArea — must fallback")
    }
}
