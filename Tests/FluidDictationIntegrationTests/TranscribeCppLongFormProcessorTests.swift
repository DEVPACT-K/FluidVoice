@testable import FluidVoice_Debug
import XCTest

final class CohereCppLongFormTests: XCTestCase {
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
    }

    func testEarlierCJKDoesNotBreakEnglishBoundarySpacing() {
        XCTAssertEqual(
            CohereTranscribeCppLongFormProcessor.merge(["中文结束. English starts", "starts here"]),
            "中文结束. English starts here"
        )
    }

    func testMergeIgnoresEmptyChunks() {
        XCTAssertEqual(
            CohereTranscribeCppLongFormProcessor.merge(["", "  ", "complete transcript"]),
            "complete transcript"
        )
    }
}
