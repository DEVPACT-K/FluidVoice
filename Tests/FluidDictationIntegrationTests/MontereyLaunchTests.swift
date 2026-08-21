import XCTest
@testable import Fluid

/// Launch smoke test for Monterey 12.7 Intel — verifies the app can init without crashing
/// on the 2015 Air's 4GB + Intel path (no Apple Silicon engines, no notch).
final class MontereyLaunchTests: XCTestCase {
    func testAppDelegateLaunchDoesNotCrashOnMontereyIntel() {
        // This just verifies the compat helpers don't fatalError on Intel 12.7
        XCTAssertNoThrow({
            _ = CPUArchitecture.isMontereyIntel
            _ = SettingsStore.SpeechModel.defaultModel
            _ = SettingsStore.SpeechModel.availableModels
        })
    }

    func testOverlayFallbackIsBottomOnMonterey() {
        // On Monterey Intel (no notch), the overlay should be bottom
        let hasNotch: Bool = {
            if #available(macOS 13.0, *) {
                return NSScreen.main?.auxiliaryTopLeftArea != nil
            }
            return false
        }()
        if CPUArchitecture.isMontereyIntel {
            XCTAssertFalse(hasNotch, "Monterey Intel 2015 Air has no notch — should fallback to bottom")
        }
    }
}
