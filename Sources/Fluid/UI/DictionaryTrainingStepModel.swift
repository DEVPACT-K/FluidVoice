//
//  DictionaryTrainingStepModel.swift
//  fluid
//
//  Pure step-derivation and expansion-resolution logic for the "Train by Voice"
//  accordion composer in CustomDictionaryView. Kept free of SwiftUI/@State so it
//  can be unit tested directly.
//

import Foundation

/// The three always-visible steps of the "Train by Voice" accordion composer.
enum DictionaryTrainingStep: Int, CaseIterable, Equatable {
    case word
    case record
    case verify
}

/// Immutable snapshot of the primitive training state the step model derives from.
struct DictionaryTrainingSnapshot: Equatable {
    let normalizedWord: String
    let consecutiveCoveredCaptures: Int
    let pronunciationEnrollmentCount: Int
    let lastTrainingOutput: String
    let lastTrainingOutputIsCovered: Bool
    let trainingVariantsIsEmpty: Bool
    let activePronunciationMatching: Bool
}

enum DictionaryTrainingStepModel {
    /// Single source of truth for whether the last training output counts as
    /// "covered"; `CustomDictionaryView.trainingOutputIsCovered` delegates to this.
    static func isOutputCovered(
        lastTrainingOutputIsCovered: Bool,
        pronunciationEnrollmentCount: Int,
        activePronunciationMatching: Bool
    ) -> Bool {
        if activePronunciationMatching {
            return pronunciationEnrollmentCount > 0
        }
        return lastTrainingOutputIsCovered
    }

    /// Single source of truth for `trainingAlreadyCorrectWithoutReplacement`;
    /// CustomDictionaryView delegates to this.
    static func alreadyCorrectWithoutReplacement(
        _ snapshot: DictionaryTrainingSnapshot,
        readyCoveredCount: Int
    ) -> Bool {
        if snapshot.activePronunciationMatching {
            return snapshot.trainingVariantsIsEmpty &&
                !snapshot.lastTrainingOutput.isEmpty &&
                snapshot.lastTrainingOutput.caseInsensitiveCompare(snapshot.normalizedWord) == .orderedSame &&
                snapshot.pronunciationEnrollmentCount >= readyCoveredCount
        }

        let outputIsCovered = self.isOutputCovered(
            lastTrainingOutputIsCovered: snapshot.lastTrainingOutputIsCovered,
            pronunciationEnrollmentCount: snapshot.pronunciationEnrollmentCount,
            activePronunciationMatching: snapshot.activePronunciationMatching
        )
        return snapshot.trainingVariantsIsEmpty &&
            outputIsCovered &&
            !snapshot.lastTrainingOutput.isEmpty &&
            snapshot.lastTrainingOutput.caseInsensitiveCompare(snapshot.normalizedWord) == .orderedSame &&
            snapshot.consecutiveCoveredCaptures >= readyCoveredCount
    }

    /// Single source of truth for `trainingFinalOutputIsReady`;
    /// CustomDictionaryView delegates to this.
    static func finalOutputIsReady(
        _ snapshot: DictionaryTrainingSnapshot,
        readyCoveredCount: Int
    ) -> Bool {
        let alreadyCorrect = self.alreadyCorrectWithoutReplacement(
            snapshot,
            readyCoveredCount: readyCoveredCount
        )

        if snapshot.activePronunciationMatching {
            return !alreadyCorrect && snapshot.pronunciationEnrollmentCount >= readyCoveredCount
        }

        let outputIsCovered = self.isOutputCovered(
            lastTrainingOutputIsCovered: snapshot.lastTrainingOutputIsCovered,
            pronunciationEnrollmentCount: snapshot.pronunciationEnrollmentCount,
            activePronunciationMatching: snapshot.activePronunciationMatching
        )
        return !alreadyCorrect && outputIsCovered && snapshot.consecutiveCoveredCaptures >= readyCoveredCount
    }

    /// Pure derivation of which step the composer logically represents right now,
    /// from primitive training state (not pre-derived booleans).
    ///
    /// - `.word` if the word is empty.
    /// - `.verify` if the capture is ready, already-correct, or the verify lock
    ///   (`hasReachedVerify`) has been latched (prevents a post-ready missed
    ///   capture from snapping the accordion back to `.record`).
    /// - `.record` otherwise.
    static func derivedStep(
        _ snapshot: DictionaryTrainingSnapshot,
        readyCoveredCount: Int,
        hasReachedVerify: Bool
    ) -> DictionaryTrainingStep {
        guard !snapshot.normalizedWord.isEmpty else { return .word }

        let ready = self.finalOutputIsReady(
            snapshot,
            readyCoveredCount: readyCoveredCount
        )
        let alreadyCorrect = self.alreadyCorrectWithoutReplacement(
            snapshot,
            readyCoveredCount: readyCoveredCount
        )

        if ready || alreadyCorrect || hasReachedVerify {
            return .verify
        }
        return .record
    }

    /// Pure resolution of which step's body should be expanded, given the derived
    /// step and the accordion's interaction state. Priority order (highest first):
    ///
    /// 1. Recording lock (`isRecordingLocked`) always wins: `.record` is expanded,
    ///    no matter what the derived step or manual override say.
    /// 2. Word-field focus always wins next: `.word` stays expanded so typing is
    ///    never interrupted.
    /// 3. A manual header tap (`manualOverride`) wins over the derived step.
    /// 4. Otherwise, the derived step is expanded.
    static func resolveExpandedStep(
        derived: DictionaryTrainingStep,
        manualOverride: DictionaryTrainingStep?,
        isRecordingLocked: Bool,
        isWordFieldFocused: Bool
    ) -> DictionaryTrainingStep {
        if isRecordingLocked {
            return .record
        }
        if isWordFieldFocused {
            return .word
        }
        if let manualOverride {
            return manualOverride
        }
        return derived
    }
}

/// Testable copy for the "Train by Voice" accordion step subtitles. Kept free of
/// SwiftUI/@State so the latched post-ready-miss subtitle and the already-correct
/// subtitle can be pinned by unit tests.
enum DictionaryTrainingStepCopy {
    /// Subtitle for the Record step header. When the derived step is `.verify` only
    /// because of the post-ready-miss latch (`progress < total`), the real progress
    /// is shown instead of a false "Recognized total/total".
    static func recordStepSubtitle(
        derivedStep: DictionaryTrainingStep,
        preloadedCaptureCount: Int?,
        progress: Int,
        total: Int
    ) -> String {
        switch derivedStep {
        case .word:
            return "Waiting for word…"
        case .verify:
            if progress >= total {
                return "✓ Recognized \(total)/\(total)"
            }
            return "Recognized \(progress)/\(total) — record again"
        case .record:
            if let preloadedCaptureCount {
                return "Loaded \(preloadedCaptureCount) saved \(preloadedCaptureCount == 1 ? "capture" : "captures")"
            }
            return "Recorded \(progress)/\(total) — keep going"
        }
    }

    /// Subtitle for the Verify step header. The already-correct-without-replacement
    /// state (Save disabled, "Nothing to Save") is distinguished from ready-to-save.
    static func verifyStepSubtitle(isReady: Bool, isAlreadyCorrect: Bool) -> String {
        if isAlreadyCorrect {
            return "No replacement needed"
        }
        return isReady ? "Ready to save" : "—"
    }
}
