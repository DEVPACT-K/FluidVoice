@testable import FluidVoice_Debug
import XCTest

final class CohereCppLongFormTests: XCTestCase {
    func testCohereDisablesGrowingPrefixStreamingPreviews() {
        XCTAssertFalse(SettingsStore.SpeechModel.cohereTranscribeSixBit.supportsStreaming)
    }

    func testRangesStayBoundedAndOverlap() {
        XCTAssertEqual(
            CohereTranscribeCppLongFormProcessor.ranges(
                sampleCount: 70,
                sampleRate: 10,
                maximumChunkSeconds: 3,
                overlapSeconds: 1
            ),
            [0..<30, 20..<50, 40..<70]
        )
    }

    func testRangesKeepShortAudioWhole() {
        XCTAssertEqual(
            CohereTranscribeCppLongFormProcessor.ranges(sampleCount: 20, sampleRate: 10),
            [0..<20]
        )
        XCTAssertTrue(CohereTranscribeCppLongFormProcessor.ranges(sampleCount: 0, sampleRate: 10).isEmpty)
    }

    func testMergeRemovesRepeatedWordsAcrossPunctuation() {
        XCTAssertEqual(
            CohereTranscribeCppLongFormProcessor.merge([
                "GPU, CPU, memory, networking.",
                "memory networking storage and power.",
            ]),
            "GPU, CPU, memory, networking. storage and power."
        )
    }

    func testMergeToleratesMinorRecognitionDrift() {
        XCTAssertEqual(
            CohereTranscribeCppLongFormProcessor.merge([
                "solving the networking",
                "the network storage problem",
            ]),
            "solving the networking storage problem"
        )
    }

    func testMergeAlignsContractionsAndHyphenatedWords() {
        XCTAssertEqual(
            CohereTranscribeCppLongFormProcessor.merge([
                "I'm sure there are trade-offs there.",
                "I'm sure there's tradeoffs there. Plus, specialists collaborate.",
            ]),
            "I'm sure there are trade-offs there. Plus, specialists collaborate."
        )
        XCTAssertEqual(
            CohereTranscribeCppLongFormProcessor.merge([
                "networking chips and scale-up switches and scale-out switches.",
                "Scale up switches and scale out switches. Cooling matters.",
            ]),
            "networking chips and scale-up switches and scale-out switches. Cooling matters."
        )
    }

    func testMergeHandlesCJKWithoutAddingSpaces() {
        XCTAssertEqual(
            CohereTranscribeCppLongFormProcessor.merge(["这是一个测试结果", "测试结果非常准确"]),
            "这是一个测试结果非常准确"
        )
        XCTAssertEqual(
            CohereTranscribeCppLongFormProcessor.merge(["这是一个测试，结果", "测试结果非常准确"]),
            "这是一个测试，结果非常准确"
        )
    }

    func testMergeToleratesMinorCJKRecognitionDrift() {
        XCTAssertEqual(
            CohereTranscribeCppLongFormProcessor.merge(["这是一个测试结果", "测试结杲非常准确"]),
            "这是一个测试结果非常准确"
        )
        XCTAssertEqual(
            CohereTranscribeCppLongFormProcessor.merge(["测试结果", "测试结结果非常准确"]),
            "测试结果非常准确"
        )
        XCTAssertEqual(
            CohereTranscribeCppLongFormProcessor.merge(["测试结果", "试结果非常准确"]),
            "测试结果非常准确"
        )
    }

    func testMergePreservesCJKAndMixedScriptBoundariesWithoutOverlap() {
        XCTAssertEqual(
            CohereTranscribeCppLongFormProcessor.merge(["한국어 테스트", "새로운 문장"]),
            "한국어 테스트 새로운 문장"
        )
        XCTAssertEqual(
            CohereTranscribeCppLongFormProcessor.merge(["中文 hello", "world 中文"]),
            "中文 hello world 中文"
        )
        XCTAssertEqual(
            CohereTranscribeCppLongFormProcessor.merge(["第一句", "第二句"]),
            "第一句第二句"
        )
    }

    func testEarlierCJKDoesNotBreakEnglishBoundarySpacing() {
        XCTAssertEqual(
            CohereTranscribeCppLongFormProcessor.merge(["中文结束. English starts", "starts here"]),
            "中文结束. English starts here"
        )
        XCTAssertEqual(
            CohereTranscribeCppLongFormProcessor.merge(["中", "a"]),
            "中 a"
        )
    }

    func testMergeIgnoresEmptyChunks() {
        XCTAssertEqual(
            CohereTranscribeCppLongFormProcessor.merge(["", "  ", "complete transcript"]),
            "complete transcript"
        )
    }

    func testMergeRejectsUnrelatedShortFuzzyWords() {
        XCTAssertEqual(
            CohereTranscribeCppLongFormProcessor.merge(["turn on", "burn in slowly"]),
            "turn on burn in slowly"
        )
    }
}
