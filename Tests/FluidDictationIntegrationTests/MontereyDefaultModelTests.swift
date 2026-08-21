import XCTest
@testable import Fluid

final class MontereyDefaultModelTests: XCTestCase {
    func testMontereyIntelDefaultsToTiny() {
        // Monterey Intel should default to Tiny for fast clean path (not Base)
        if CPUArchitecture.isMontereyIntel {
            XCTAssertEqual(SettingsStore.SpeechModel.defaultModel, .whisperTiny, "Monterey Intel must default to Tiny")
        }
    }
}
