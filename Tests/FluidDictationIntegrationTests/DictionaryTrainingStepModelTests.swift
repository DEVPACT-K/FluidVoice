@testable import FluidVoice_Debug
import XCTest

final class DictionaryTrainingStepModelTests: XCTestCase {
    // Reference the production constant so a change to the ready threshold fails
    // these tests instead of silently diverging from the view.
    private var readyCoveredCount: Int { CustomDictionaryTrainingMerge.readyCoveredCount }

    private func derived(
        word: String = "FluidVoice",
        consecutiveCoveredCaptures: Int = 0,
        pronunciationEnrollmentCount: Int = 0,
        lastTrainingOutput: String = "",
        lastTrainingOutputIsCovered: Bool = false,
        trainingVariantsIsEmpty: Bool = true,
        activePronunciationMatching: Bool = false,
        hasReachedVerify: Bool = false
    ) -> DictionaryTrainingStep {
        let snapshot = DictionaryTrainingSnapshot(
            normalizedWord: word,
            consecutiveCoveredCaptures: consecutiveCoveredCaptures,
            pronunciationEnrollmentCount: pronunciationEnrollmentCount,
            lastTrainingOutput: lastTrainingOutput,
            lastTrainingOutputIsCovered: lastTrainingOutputIsCovered,
            trainingVariantsIsEmpty: trainingVariantsIsEmpty,
            activePronunciationMatching: activePronunciationMatching
        )
        return DictionaryTrainingStepModel.derivedStep(
            snapshot,
            readyCoveredCount: self.readyCoveredCount,
            hasReachedVerify: hasReachedVerify
        )
    }

    // MARK: - derivedStep

    func testEmptyWordDerivesWordStep() {
        // normalizedWord is expected pre-trimmed by the caller (matches
        // CustomDictionaryView.normalizedTrainingReplacement), so only "" counts as empty.
        XCTAssertEqual(self.derived(word: ""), .word)
    }

    func testNonEmptyWordWithNoProgressDerivesRecordStep() {
        XCTAssertEqual(self.derived(word: "FluidVoice"), .record)
    }

    func testReadyAfterThreeConsecutiveCoveredCapturesDerivesVerifyStep() {
        let step = self.derived(
            consecutiveCoveredCaptures: 3,
            lastTrainingOutput: "FluidVoice",
            lastTrainingOutputIsCovered: true,
            trainingVariantsIsEmpty: false
        )
        XCTAssertEqual(step, .verify)
    }

    func testAlmostReadyStaysOnRecordStep() {
        let step = self.derived(
            consecutiveCoveredCaptures: 2,
            lastTrainingOutput: "FluidVoice",
            lastTrainingOutputIsCovered: true,
            trainingVariantsIsEmpty: false
        )
        XCTAssertEqual(step, .record)
    }

    func testAlreadyCorrectWithoutReplacementDerivesVerifyStep() {
        // No captured variants, output already matches the word 3x in a row.
        let step = self.derived(
            consecutiveCoveredCaptures: 3,
            lastTrainingOutput: "FluidVoice",
            lastTrainingOutputIsCovered: true,
            trainingVariantsIsEmpty: true
        )
        XCTAssertEqual(step, .verify)
    }

    func testPronunciationMatchingBranchUsesEnrollmentCountNotConsecutiveCaptures() {
        // Consecutive captures is 0 (irrelevant in this branch); enrollment count drives readiness.
        let notReady = self.derived(
            consecutiveCoveredCaptures: 0,
            pronunciationEnrollmentCount: 2,
            trainingVariantsIsEmpty: false,
            activePronunciationMatching: true
        )
        XCTAssertEqual(notReady, .record)

        let ready = self.derived(
            consecutiveCoveredCaptures: 0,
            pronunciationEnrollmentCount: 3,
            trainingVariantsIsEmpty: false,
            activePronunciationMatching: true
        )
        XCTAssertEqual(ready, .verify)
    }

    func testVerifyLockSurvivesPostReadyMissedCapture() {
        // consecutiveCoveredCaptures reset to 0 (a miss after being ready), but the
        // verify lock is latched — must NOT snap back to .record.
        let step = self.derived(
            consecutiveCoveredCaptures: 0,
            lastTrainingOutput: "FluidVoice",
            lastTrainingOutputIsCovered: false,
            trainingVariantsIsEmpty: false,
            hasReachedVerify: true
        )
        XCTAssertEqual(step, .verify)
    }

    func testPreloadedVariantsStateDerivesRecordStepNotVerify() {
        // Preload: chips exist (trainingVariantsIsEmpty == false) but nothing recorded
        // this session yet (consecutiveCoveredCaptures == 0, no lastTrainingOutput).
        let step = self.derived(
            consecutiveCoveredCaptures: 0,
            lastTrainingOutput: "",
            lastTrainingOutputIsCovered: false,
            trainingVariantsIsEmpty: false
        )
        XCTAssertEqual(step, .record)
    }

    func testEmptyWordGuardOutranksVerifyLatch() {
        // Word cleared after reaching Verify: the empty-word guard must win over the
        // latch, dropping back to .word. Load-bearing for the word-edit reset flow.
        XCTAssertEqual(self.derived(word: "", hasReachedVerify: true), .word)
    }

    func testCoveredCapturesAreCaseInsensitiveAgainstWord() {
        // lastTrainingOutput differs only in case from the word — must still count as
        // an already-correct/ready match.
        let step = self.derived(
            word: "FluidVoice",
            consecutiveCoveredCaptures: 3,
            lastTrainingOutput: "fluidvoice",
            lastTrainingOutputIsCovered: true,
            trainingVariantsIsEmpty: true
        )
        XCTAssertEqual(step, .verify)
    }

    // MARK: - finalOutputIsReady / alreadyCorrectWithoutReplacement

    private func finalReady(
        word: String = "FluidVoice",
        consecutiveCoveredCaptures: Int = 0,
        pronunciationEnrollmentCount: Int = 0,
        lastTrainingOutput: String = "",
        lastTrainingOutputIsCovered: Bool = false,
        trainingVariantsIsEmpty: Bool = true,
        activePronunciationMatching: Bool = false
    ) -> Bool {
        DictionaryTrainingStepModel.finalOutputIsReady(
            DictionaryTrainingSnapshot(
                normalizedWord: word,
                consecutiveCoveredCaptures: consecutiveCoveredCaptures,
                pronunciationEnrollmentCount: pronunciationEnrollmentCount,
                lastTrainingOutput: lastTrainingOutput,
                lastTrainingOutputIsCovered: lastTrainingOutputIsCovered,
                trainingVariantsIsEmpty: trainingVariantsIsEmpty,
                activePronunciationMatching: activePronunciationMatching
            ),
            readyCoveredCount: self.readyCoveredCount
        )
    }

    private func alreadyCorrect(
        word: String = "FluidVoice",
        consecutiveCoveredCaptures: Int = 0,
        pronunciationEnrollmentCount: Int = 0,
        lastTrainingOutput: String = "",
        lastTrainingOutputIsCovered: Bool = false,
        trainingVariantsIsEmpty: Bool = true,
        activePronunciationMatching: Bool = false
    ) -> Bool {
        DictionaryTrainingStepModel.alreadyCorrectWithoutReplacement(
            DictionaryTrainingSnapshot(
                normalizedWord: word,
                consecutiveCoveredCaptures: consecutiveCoveredCaptures,
                pronunciationEnrollmentCount: pronunciationEnrollmentCount,
                lastTrainingOutput: lastTrainingOutput,
                lastTrainingOutputIsCovered: lastTrainingOutputIsCovered,
                trainingVariantsIsEmpty: trainingVariantsIsEmpty,
                activePronunciationMatching: activePronunciationMatching
            ),
            readyCoveredCount: self.readyCoveredCount
        )
    }

    func testAlreadyCorrectRequiresNoCapturedVariants() {
        // Same covered output 3x, but variants still present → not "already correct"
        // (there is something to save), so it's ready-to-save instead.
        XCTAssertFalse(self.alreadyCorrect(
            consecutiveCoveredCaptures: 3,
            lastTrainingOutput: "FluidVoice",
            lastTrainingOutputIsCovered: true,
            trainingVariantsIsEmpty: false
        ))
        XCTAssertTrue(self.finalReady(
            consecutiveCoveredCaptures: 3,
            lastTrainingOutput: "FluidVoice",
            lastTrainingOutputIsCovered: true,
            trainingVariantsIsEmpty: false
        ))
    }

    func testAlreadyCorrectImpliesFinalOutputNotReady() {
        // The Save-disabled invariant: when nothing needs saving, final output is not
        // "ready" (there is no replacement to add).
        let args: (Int, String, Bool, Bool) = (3, "FluidVoice", true, true)
        XCTAssertTrue(self.alreadyCorrect(
            consecutiveCoveredCaptures: args.0,
            lastTrainingOutput: args.1,
            lastTrainingOutputIsCovered: args.2,
            trainingVariantsIsEmpty: args.3
        ))
        XCTAssertFalse(self.finalReady(
            consecutiveCoveredCaptures: args.0,
            lastTrainingOutput: args.1,
            lastTrainingOutputIsCovered: args.2,
            trainingVariantsIsEmpty: args.3
        ))
    }

    func testFinalReadyForCoveredNonMatchingOutput() {
        // Covered by dictionary but output != word (a real replacement to save):
        // ready must be true, alreadyCorrect false.
        XCTAssertTrue(self.finalReady(
            consecutiveCoveredCaptures: 3,
            lastTrainingOutput: "fluid voice",
            lastTrainingOutputIsCovered: true,
            trainingVariantsIsEmpty: false
        ))
        XCTAssertFalse(self.alreadyCorrect(
            consecutiveCoveredCaptures: 3,
            lastTrainingOutput: "fluid voice",
            lastTrainingOutputIsCovered: true,
            trainingVariantsIsEmpty: false
        ))
    }

    func testPronunciationEnrollmentBoundary() {
        // readyCoveredCount - 1 enrollments is not ready; == readyCoveredCount is.
        XCTAssertFalse(self.finalReady(
            pronunciationEnrollmentCount: self.readyCoveredCount - 1,
            trainingVariantsIsEmpty: false,
            activePronunciationMatching: true
        ))
        XCTAssertTrue(self.finalReady(
            pronunciationEnrollmentCount: self.readyCoveredCount,
            trainingVariantsIsEmpty: false,
            activePronunciationMatching: true
        ))
    }

    func testPronunciationAlreadyCorrectWithEnoughEnrollments() {
        // No variants to save, output matches word, enrollments sufficient → already
        // correct, and therefore not ready-to-save.
        XCTAssertTrue(self.alreadyCorrect(
            pronunciationEnrollmentCount: self.readyCoveredCount,
            lastTrainingOutput: "FluidVoice",
            trainingVariantsIsEmpty: true,
            activePronunciationMatching: true
        ))
        XCTAssertFalse(self.finalReady(
            pronunciationEnrollmentCount: self.readyCoveredCount,
            lastTrainingOutput: "FluidVoice",
            trainingVariantsIsEmpty: true,
            activePronunciationMatching: true
        ))
    }

    // MARK: - resolveExpandedStep

    func testRecordingLockOverridesManualOverrideAndDerivedStep() {
        let resolved = DictionaryTrainingStepModel.resolveExpandedStep(
            derived: .verify,
            manualOverride: .word,
            isRecordingLocked: true,
            isWordFieldFocused: false
        )
        XCTAssertEqual(resolved, .record)
    }

    func testWordFieldFocusPinsWordStepEvenWithManualOverrideElsewhere() {
        let resolved = DictionaryTrainingStepModel.resolveExpandedStep(
            derived: .record,
            manualOverride: .verify,
            isRecordingLocked: false,
            isWordFieldFocused: true
        )
        XCTAssertEqual(resolved, .word)
    }

    func testManualOverrideWinsOverDerivedStepWhenNoLockOrFocus() {
        let resolved = DictionaryTrainingStepModel.resolveExpandedStep(
            derived: .record,
            manualOverride: .verify,
            isRecordingLocked: false,
            isWordFieldFocused: false
        )
        XCTAssertEqual(resolved, .verify)
    }

    func testFallsBackToDerivedStepWithNoOverrideLockOrFocus() {
        let resolved = DictionaryTrainingStepModel.resolveExpandedStep(
            derived: .record,
            manualOverride: nil,
            isRecordingLocked: false,
            isWordFieldFocused: false
        )
        XCTAssertEqual(resolved, .record)
    }

    func testRecordingLockWinsEvenWithWordFieldFocused() {
        // Recording lock is priority 1, above word-field focus (priority 2).
        let resolved = DictionaryTrainingStepModel.resolveExpandedStep(
            derived: .word,
            manualOverride: nil,
            isRecordingLocked: true,
            isWordFieldFocused: true
        )
        XCTAssertEqual(resolved, .record)
    }

    // MARK: - Latched post-ready-miss subtitle

    /// Mirrors `CustomDictionaryView.trainingReadinessProgress` for the
    /// non-pronunciation-matching branch, using the model's single-source predicates
    /// so the test exercises the same progress the view would show.
    private func readinessProgress(
        consecutiveCoveredCaptures: Int,
        lastTrainingOutputIsCovered: Bool,
        pronunciationEnrollmentCount: Int = 0,
        activePronunciationMatching: Bool = false,
        trainingVariantsIsEmpty: Bool = true,
        lastTrainingOutput: String = "FluidVoice",
        normalizedWord: String = "FluidVoice"
    ) -> Int {
        let snapshot = DictionaryTrainingSnapshot(
            normalizedWord: normalizedWord,
            consecutiveCoveredCaptures: consecutiveCoveredCaptures,
            pronunciationEnrollmentCount: pronunciationEnrollmentCount,
            lastTrainingOutput: lastTrainingOutput,
            lastTrainingOutputIsCovered: lastTrainingOutputIsCovered,
            trainingVariantsIsEmpty: trainingVariantsIsEmpty,
            activePronunciationMatching: activePronunciationMatching
        )
        let total = self.readyCoveredCount
        if DictionaryTrainingStepModel.alreadyCorrectWithoutReplacement(snapshot, readyCoveredCount: total) {
            return total
        }
        let covered = DictionaryTrainingStepModel.isOutputCovered(
            lastTrainingOutputIsCovered: snapshot.lastTrainingOutputIsCovered,
            pronunciationEnrollmentCount: snapshot.pronunciationEnrollmentCount,
            activePronunciationMatching: snapshot.activePronunciationMatching
        )
        return covered ? min(snapshot.consecutiveCoveredCaptures, total) : 0
    }

    func testLatchedPostReadyMissDoesNotClaimRecognizedTotal() {
        // Post-ready missed capture: the verify latch holds derivedStep at .verify
        // while consecutive covered captures reset to 0 and the last output is no
        // longer covered. The Record header subtitle must show the real progress
        // (0/total) and must NOT claim "Recognized total/total".
        let total = self.readyCoveredCount
        let snapshot = DictionaryTrainingSnapshot(
            normalizedWord: "FluidVoice",
            consecutiveCoveredCaptures: 0,
            pronunciationEnrollmentCount: 0,
            lastTrainingOutput: "fluid voice",
            lastTrainingOutputIsCovered: false,
            trainingVariantsIsEmpty: false,
            activePronunciationMatching: false
        )

        let step = DictionaryTrainingStepModel.derivedStep(
            snapshot,
            readyCoveredCount: total,
            hasReachedVerify: true
        )
        XCTAssertEqual(step, .verify)

        let resolved = DictionaryTrainingStepModel.resolveExpandedStep(
            derived: step,
            manualOverride: nil,
            isRecordingLocked: false,
            isWordFieldFocused: false
        )
        XCTAssertEqual(resolved, .verify)

        let progress = self.readinessProgress(
            consecutiveCoveredCaptures: snapshot.consecutiveCoveredCaptures,
            lastTrainingOutputIsCovered: snapshot.lastTrainingOutputIsCovered,
            trainingVariantsIsEmpty: snapshot.trainingVariantsIsEmpty,
            lastTrainingOutput: snapshot.lastTrainingOutput
        )
        XCTAssertEqual(progress, 0, "latched post-ready-miss must read zero progress")

        let subtitle = DictionaryTrainingStepCopy.recordStepSubtitle(
            derivedStep: step,
            preloadedCaptureCount: nil,
            progress: progress,
            total: total
        )
        XCTAssertNotEqual(subtitle, "✓ Recognized \(total)/\(total)")
        XCTAssertTrue(subtitle.contains("0/\(total)"), "expected real progress, got: \(subtitle)")
        XCTAssertTrue(subtitle.contains("record again"), "expected a record-again nudge, got: \(subtitle)")
    }

    func testGenuinelyReadyRecordSubtitleShowsRecognizedTotal() {
        // Positive counterpart: when progress actually reaches total, the Record
        // header subtitle shows the complete "✓ Recognized total/total".
        let total = self.readyCoveredCount
        let subtitle = DictionaryTrainingStepCopy.recordStepSubtitle(
            derivedStep: .verify,
            preloadedCaptureCount: nil,
            progress: total,
            total: total
        )
        XCTAssertEqual(subtitle, "✓ Recognized \(total)/\(total)")
    }

    // MARK: - Verify step subtitle copy

    func testVerifySubtitleAlreadyCorrectSaysNoReplacementNeeded() {
        // alreadyCorrectWithoutReplacement: Save is disabled ("Nothing to Save"), so
        // the Verify header must not say "Ready to save".
        let subtitle = DictionaryTrainingStepCopy.verifyStepSubtitle(
            isReady: false,
            isAlreadyCorrect: true
        )
        XCTAssertEqual(subtitle, "No replacement needed")
    }

    func testVerifySubtitleReadySaysReadyToSave() {
        let subtitle = DictionaryTrainingStepCopy.verifyStepSubtitle(
            isReady: true,
            isAlreadyCorrect: false
        )
        XCTAssertEqual(subtitle, "Ready to save")
    }

    func testVerifySubtitleNotReadyShowsPlaceholder() {
        let subtitle = DictionaryTrainingStepCopy.verifyStepSubtitle(
            isReady: false,
            isAlreadyCorrect: false
        )
        XCTAssertEqual(subtitle, "—")
    }
}
