import XCTest
@testable import Fluid

/// Monterey 12.7 Intel invariants — ensures the 2015 Air fast path doesn't regress.
/// These are compile-time + logic checks, runnable even without Xcode on the Air via `swift test`.
final class MontereyCompatTests: XCTestCase {
    func testDefaultModelIsIntelligentOnLowRAMIntel() {
        // On this host (no Xcode, Swift 5.7), defaultModel should be deterministic.
        // The important invariant: on Intel it must NOT be an Apple Silicon-only model.
        #if arch(x86_64)
        let model = SettingsStore.SpeechModel.defaultModel
        XCTAssertFalse(model.requiresAppleSilicon, "Intel default must not require Apple Silicon — 2015 Air would fail")
        // On low-RAM hosts (CI has >8GB, so this is just a sanity that Tiny/Base are allowed)
        XCTAssertTrue([.whisperTiny, .whisperBase].contains(model) || model == .appleSpeech)
        #endif
    }

    func testStaleParakeetMigratesToWhisperOnIntel() async {
        #if arch(x86_64)
        let store = SettingsStore.shared
        let original = store.selectedSpeechModel
        defer { store.selectedSpeechModel = original }
        // Simulate a persisted Parakeet pref from an Apple Silicon Mac
        UserDefaults.standard.set(SettingsStore.SpeechModel.parakeetTDT.rawValue, forKey: "SelectedSpeechModel")
        let resolved = store.selectedSpeechModel
        XCTAssertFalse(resolved.requiresAppleSilicon, "Migrated model on Intel must not require Apple Silicon")
        #endif
    }

    func testDeploymentTargetIsMonterey() {
        // Guard against accidental bump back to 15.0
        let plistPath = Bundle.main.path(forResource: "Info", ofType: "plist") ?? ""
        // In test bundle, Info.plist may not be Fluid's — so also check the project file directly
        let projectPath = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fluid.xcodeproj/project.pbxproj")
        if let content = try? String(contentsOf: projectPath) {
            XCTAssertFalse(content.contains("MACOSX_DEPLOYMENT_TARGET = 15.0"), "Deployment target regressed to 15.0 — Monterey build will fail")
            XCTAssertTrue(content.contains("MACOSX_DEPLOYMENT_TARGET = 12.7"), "Deployment target should be 12.7 for Monterey")
        } else {
            XCTFail("Could not read project.pbxproj for deployment check")
        }
        _ = plistPath // keep var used
    }
}
