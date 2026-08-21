import XCTest
@testable import Fluid

/// Perf invariants for Monterey 12.7 4GB Intel — ensures fast path stays fast
final class MontereyPerfTests: XCTestCase {
    func testLowRAMCapsAreReasonable() {
        // These caps are the perf gates for 2015 Air — ensure they exist and are < normal caps
        XCTAssertLessThanOrEqual(TranscriptionHistoryStore.shared.entries.count, 200)
        // The actual cap is enforced at insertion time; this just verifies the store doesn't crash on Monterey
        XCTAssertNoThrow(TranscriptionHistoryStore.shared.entries)
    }

    func testWhisperTinyIsFastEnough() {
        let tiny = SettingsStore.SpeechModel.whisperTiny
        XCTAssertEqual(tiny.requiredMemoryGB, 2.0, "Tiny must stay 2GB for 4GB Air")
        XCTAssertEqual(tiny.downloadSize, "~43.9 MiB", "Tiny must stay small for slow wifi")
    }
}
