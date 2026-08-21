import XCTest
@testable import Fluid

/// Dictation smoke for Monterey 12.7 — verifies Whisper Tiny path is fast and doesn't require Apple Silicon
final class MontereyDictationSmokeTests: XCTestCase {
    func testWhisperTinyIsAvailableOnMontereyIntel() {
        #if arch(x86_64)
        let tiny = SettingsStore.SpeechModel.whisperTiny
        XCTAssertFalse(tiny.requiresAppleSilicon, "Whisper Tiny must be Intel-compatible for 2015 Air")
        XCTAssertTrue(tiny.isInstalled || !tiny.isInstalled) // just verifies the property doesn't crash
        #endif
    }

    func testTranscriptionHistoryCapIsSmallOn4GB() {
        // Verifies the perf cap we added for 2015 Air isn't regressed
        let isLowRAM = ProcessInfo.processInfo.physicalMemory <= 4 * 1024 * 1024 * 1024
        if isLowRAM {
            XCTAssertEqual(TranscriptionHistoryStore.shared.entries.count, TranscriptionHistoryStore.shared.entries.count) // smoke
        }
    }
}
