@testable import FluidVoice_Debug
import XCTest

final class TranscribeCppLongFormProcessorTests: XCTestCase {
    func testRangesStayBoundedAndOverlap() {
        XCTAssertEqual(
            TranscribeCppLongFormProcessor.ranges(
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
            TranscribeCppLongFormProcessor.ranges(sampleCount: 20, sampleRate: 10),
            [0..<20]
        )
        XCTAssertTrue(TranscribeCppLongFormProcessor.ranges(sampleCount: 0, sampleRate: 10).isEmpty)
    }

    func testMergeRemovesRepeatedWordsAcrossPunctuation() {
        XCTAssertEqual(
            TranscribeCppLongFormProcessor.merge([
                "GPU, CPU, memory, networking.",
                "memory networking storage and power.",
            ]),
            "GPU, CPU, memory, networking. storage and power."
        )
    }

    func testMergeToleratesMinorRecognitionDrift() {
        XCTAssertEqual(
            TranscribeCppLongFormProcessor.merge([
                "solving the networking",
                "the network storage problem",
            ]),
            "solving the networking storage problem"
        )
    }

    func testMergeAlignsContractionsAndHyphenatedWords() {
        XCTAssertEqual(
            TranscribeCppLongFormProcessor.merge([
                "I'm sure there are trade-offs there.",
                "I'm sure there's tradeoffs there. Plus, specialists collaborate.",
            ]),
            "I'm sure there are trade-offs there. Plus, specialists collaborate."
        )
        XCTAssertEqual(
            TranscribeCppLongFormProcessor.merge([
                "networking chips and scale-up switches and scale-out switches.",
                "Scale up switches and scale out switches. Cooling matters.",
            ]),
            "networking chips and scale-up switches and scale-out switches. Cooling matters."
        )
    }

    func testMergeHandlesCJKWithoutAddingSpaces() {
        XCTAssertEqual(
            TranscribeCppLongFormProcessor.merge(["这是一个测试结果", "测试结果非常准确"]),
            "这是一个测试结果非常准确"
        )
    }

    func testEarlierCJKDoesNotBreakEnglishBoundarySpacing() {
        XCTAssertEqual(
            TranscribeCppLongFormProcessor.merge(["中文结束. English starts", "starts here"]),
            "中文结束. English starts here"
        )
    }

    func testMergeIgnoresEmptyChunks() {
        XCTAssertEqual(
            TranscribeCppLongFormProcessor.merge(["", "  ", "complete transcript"]),
            "complete transcript"
        )
    }
}
