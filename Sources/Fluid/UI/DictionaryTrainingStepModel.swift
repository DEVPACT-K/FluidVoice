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

enum DictionaryTrainingStepModel {
    /// Replicates `trainingOutputIsCovered` (CustomDictionaryView.swift ~141-146).
    private static func isOutputCovered(
        lastTrainingOutputIsCovered: Bool,
        trainingVariantsIsEmpty: Bool,
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
        normalizedWord: String,
        consecutiveCoveredCaptures: Int,
        pronunciationEnrollmentCount: Int,
        lastTrainingOutput: String,
        lastTrainingOutputIsCovered: Bool,
        trainingVariantsIsEmpty: Bool,
        activePronunciationMatching: Bool,
        readyCoveredCount: Int
    ) -> Bool {
        if activePronunciationMatching {
            return trainingVariantsIsEmpty &&
                !lastTrainingOutput.isEmpty &&
                lastTrainingOutput.caseInsensitiveCompare(normalizedWord) == .orderedSame &&
                pronunciationEnrollmentCount >= readyCoveredCount
        }

        let outputIsCovered = self.isOutputCovered(
            lastTrainingOutputIsCovered: lastTrainingOutputIsCovered,
            trainingVariantsIsEmpty: trainingVariantsIsEmpty,
            pronunciationEnrollmentCount: pronunciationEnrollmentCount,
            activePronunciationMatching: activePronunciationMatching
        )
        return trainingVariantsIsEmpty &&
            outputIsCovered &&
            !lastTrainingOutput.isEmpty &&
            lastTrainingOutput.caseInsensitiveCompare(normalizedWord) == .orderedSame &&
            consecutiveCoveredCaptures >= readyCoveredCount
    }

    /// Single source of truth for `trainingFinalOutputIsReady`;
    /// CustomDictionaryView delegates to this.
    static func finalOutputIsReady(
        normalizedWord: String,
        consecutiveCoveredCaptures: Int,
        pronunciationEnrollmentCount: Int,
        lastTrainingOutput: String,
        lastTrainingOutputIsCovered: Bool,
        trainingVariantsIsEmpty: Bool,
        activePronunciationMatching: Bool,
        readyCoveredCount: Int
    ) -> Bool {
        let alreadyCorrect = self.alreadyCorrectWithoutReplacement(
            normalizedWord: normalizedWord,
            consecutiveCoveredCaptures: consecutiveCoveredCaptures,
            pronunciationEnrollmentCount: pronunciationEnrollmentCount,
            lastTrainingOutput: lastTrainingOutput,
            lastTrainingOutputIsCovered: lastTrainingOutputIsCovered,
            trainingVariantsIsEmpty: trainingVariantsIsEmpty,
            activePronunciationMatching: activePronunciationMatching,
            readyCoveredCount: readyCoveredCount
        )

        if activePronunciationMatching {
            return !alreadyCorrect && pronunciationEnrollmentCount >= readyCoveredCount
        }

        let outputIsCovered = self.isOutputCovered(
            lastTrainingOutputIsCovered: lastTrainingOutputIsCovered,
            trainingVariantsIsEmpty: trainingVariantsIsEmpty,
            pronunciationEnrollmentCount: pronunciationEnrollmentCount,
            activePronunciationMatching: activePronunciationMatching
        )
        return !alreadyCorrect && outputIsCovered && consecutiveCoveredCaptures >= readyCoveredCount
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
        normalizedWord: String,
        consecutiveCoveredCaptures: Int,
        pronunciationEnrollmentCount: Int,
        lastTrainingOutput: String,
        lastTrainingOutputIsCovered: Bool,
        trainingVariantsIsEmpty: Bool,
        activePronunciationMatching: Bool,
        readyCoveredCount: Int,
        hasReachedVerify: Bool
    ) -> DictionaryTrainingStep {
        guard !normalizedWord.isEmpty else { return .word }

        let ready = self.finalOutputIsReady(
            normalizedWord: normalizedWord,
            consecutiveCoveredCaptures: consecutiveCoveredCaptures,
            pronunciationEnrollmentCount: pronunciationEnrollmentCount,
            lastTrainingOutput: lastTrainingOutput,
            lastTrainingOutputIsCovered: lastTrainingOutputIsCovered,
            trainingVariantsIsEmpty: trainingVariantsIsEmpty,
            activePronunciationMatching: activePronunciationMatching,
            readyCoveredCount: readyCoveredCount
        )
        let alreadyCorrect = self.alreadyCorrectWithoutReplacement(
            normalizedWord: normalizedWord,
            consecutiveCoveredCaptures: consecutiveCoveredCaptures,
            pronunciationEnrollmentCount: pronunciationEnrollmentCount,
            lastTrainingOutput: lastTrainingOutput,
            lastTrainingOutputIsCovered: lastTrainingOutputIsCovered,
            trainingVariantsIsEmpty: trainingVariantsIsEmpty,
            activePronunciationMatching: activePronunciationMatching,
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
