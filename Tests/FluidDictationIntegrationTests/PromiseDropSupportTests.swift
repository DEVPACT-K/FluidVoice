@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Contract tests for the testable core of the promise-aware drop path (issue #219).
/// The AppKit drop view itself needs a live drag session; these tests pin down the
/// pure logic it delegates to: strategy selection from pasteboard types, and
/// per-item staging directories that cannot collide.
final class PromiseDropSupportTests: XCTestCase {
    // MARK: - Strategy selection

    func testConcreteFileURLsWinOverPromises() {
        let types = ["public.file-url", "com.apple.NSFilePromiseItemMetaData", "com.apple.pasteboard.promised-file-content-type"]
        XCTAssertEqual(PromiseDropSupport.strategy(forPasteboardTypes: types), .concreteFileURLs)
    }

    func testPromiseTypesSelectFilePromiseStrategy() {
        // Exactly what Voice Memos puts on the pasteboard (verified live 2026-07-25).
        let voiceMemosTypes = [
            "com.apple.NSFilePromiseItemMetaData",
            "com.apple.pasteboard.promised-file-name",
            "com.apple.pasteboard.promised-suggested-file-name",
            "com.apple.pasteboard.promised-file-content-type",
            "Apple files promise pasteboard type",
            "com.apple.pasteboard.NSFilePromiseID",
            "com.apple.m4a-audio",
            "com.apple.uikit.private.drag-item",
            "NSPromiseContentsPboardType",
            "com.apple.pasteboard.promised-file-url",
        ]
        XCTAssertEqual(PromiseDropSupport.strategy(forPasteboardTypes: voiceMemosTypes), .filePromise)
    }

    func testUnrelatedTypesSelectNoStrategy() {
        XCTAssertNil(PromiseDropSupport.strategy(forPasteboardTypes: ["public.utf8-plain-text", "public.rtf"]))
        XCTAssertNil(PromiseDropSupport.strategy(forPasteboardTypes: []))
    }

    func testNonAudioVisualPromiseIsRejected() {
        // A Photos-style image promise must not be accepted: staging a JPEG only
        // to fail it later is worse than refusing the drag affordance up front.
        let photosLikeTypes = [
            "com.apple.NSFilePromiseItemMetaData",
            "com.apple.pasteboard.promised-file-content-type",
            "public.jpeg",
        ]
        XCTAssertNil(PromiseDropSupport.strategy(forPasteboardTypes: photosLikeTypes))
    }

    func testMoviePromiseIsAccepted() {
        let movieTypes = [
            "com.apple.NSFilePromiseItemMetaData",
            "com.apple.pasteboard.promised-file-content-type",
            "com.apple.quicktime-movie",
        ]
        XCTAssertEqual(PromiseDropSupport.strategy(forPasteboardTypes: movieTypes), .filePromise)
    }

    // MARK: - Delivery selection

    func testTwoDistinctSameNamedModernFilesAreBothDelivered() {
        // Voice Memos are commonly all titled "New Recording": two different
        // memos in one drag stage into two receiver dirs with the same file
        // name. Both are real files — neither may be collapsed as a duplicate.
        let memoA = URL(fileURLWithPath: "/tmp/item-A/New Recording.m4a")
        let memoB = URL(fileURLWithPath: "/tmp/item-B/New Recording.m4a")
        let delivered = PromiseDropSupport.selectDelivery(modern: [memoA, memoB], legacy: [], data: [])
        XCTAssertEqual(delivered, [memoA, memoB])
    }

    func testFallbackCopiesOfDeliveredNamesAreSuppressed() {
        let modern = URL(fileURLWithPath: "/tmp/item-A/Lick Mill Blvd.m4a")
        let legacyDupe = URL(fileURLWithPath: "/tmp/item-L/Lick Mill Blvd.m4a")
        let dataDupe = URL(fileURLWithPath: "/tmp/item-D/Lick Mill Blvd.m4a")
        let delivered = PromiseDropSupport.selectDelivery(modern: [modern], legacy: [legacyDupe], data: [dataDupe])
        XCTAssertEqual(delivered, [modern], "legacy/data copies of an already-delivered name are the same dragged item")
    }

    func testFallbackOnlyDeliveryUsesLegacyThenData() {
        let legacyFile = URL(fileURLWithPath: "/tmp/item-L/Memo.m4a")
        let dataDupe = URL(fileURLWithPath: "/tmp/item-D/Memo.m4a")
        let dataOnly = URL(fileURLWithPath: "/tmp/item-D/Other.m4a")
        let delivered = PromiseDropSupport.selectDelivery(modern: [], legacy: [legacyFile], data: [dataDupe, dataOnly])
        XCTAssertEqual(delivered, [legacyFile, dataOnly])
    }

    // MARK: - Staging directories

    func testEachItemGetsAUniqueStagingDirectory() throws {
        let session = try PromiseDropSupport.StagingSession()
        defer { session.removeAll() }

        let dirA = try session.makeItemDirectory()
        let dirB = try session.makeItemDirectory()

        XCTAssertNotEqual(dirA, dirB, "two promised files named identically must never share a staging dir")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirB.path))

        // Identically-named files in the two dirs must coexist.
        try Data([0x01]).write(to: dirA.appendingPathComponent("New Recording.m4a"))
        try Data([0x02]).write(to: dirB.appendingPathComponent("New Recording.m4a"))
        XCTAssertEqual(try Data(contentsOf: dirA.appendingPathComponent("New Recording.m4a")), Data([0x01]))
        XCTAssertEqual(try Data(contentsOf: dirB.appendingPathComponent("New Recording.m4a")), Data([0x02]))
    }

    func testStagingDirectoriesLiveUnderTemporaryDirectory() throws {
        let session = try PromiseDropSupport.StagingSession()
        defer { session.removeAll() }

        let dir = try session.makeItemDirectory()
        let tempPath = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        XCTAssertTrue(
            dir.resolvingSymlinksInPath().path.hasPrefix(tempPath),
            "staging must be under the user temp dir, not next to user files"
        )
    }

    func testRemoveAllDeletesEverything() throws {
        let session = try PromiseDropSupport.StagingSession()
        let dirA = try session.makeItemDirectory()
        let dirB = try session.makeItemDirectory()
        try Data([0x01]).write(to: dirA.appendingPathComponent("a.m4a"))

        session.removeAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: dirA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirB.path))
    }

    // MARK: - Sweep selection

    func testSweepNeverIncludesADeliveredFilesDirectoryDespiteTrailingSlashDifferences() {
        // Regression: dirs built with appendingPathComponent (no trailing slash)
        // vs. deletingLastPathComponent() of a delivered file (trailing slash)
        // compare unequal as URLs — the sweep once deleted a delivered file.
        let base = URL(fileURLWithPath: "/tmp/PromiseDrop-test")
        let dataDir = base.appendingPathComponent("item-data")
        let legacyDir = base.appendingPathComponent("item-legacy")
        let deliveredFile = URL(fileURLWithPath: "/tmp/PromiseDrop-test/item-data/", isDirectory: true)
            .appendingPathComponent("Memo.m4a")

        let sweep = PromiseDropSupport.sweepableDirs(allDirs: [dataDir, legacyDir], deliveredFiles: [deliveredFile])

        XCTAssertEqual(sweep, [legacyDir], "the delivered file's dir must never be swept")
    }

    func testSweepRemovesAllDirsWhenNothingDelivered() {
        let dirA = URL(fileURLWithPath: "/tmp/PromiseDrop-test/item-a")
        let dirB = URL(fileURLWithPath: "/tmp/PromiseDrop-test/item-b")
        XCTAssertEqual(PromiseDropSupport.sweepableDirs(allDirs: [dirA, dirB], deliveredFiles: []), [dirA, dirB])
    }

    // MARK: - dirsSafeToRemoveNow (findings F1 / F9)

    func testDirsSafeToRemoveNowExcludesPendingReceiverDirsEvenWhenNothingDelivered() {
        // Regression for F1: an empty delivery result must not sweep a pending
        // receiver's staging dir — deleting the destination out from under an
        // in-flight NSFilePromiseReceiver wedges the source app's drag machinery.
        let pendingDir = URL(fileURLWithPath: "/tmp/PromiseDrop-test/item-pending")
        let deadDir = URL(fileURLWithPath: "/tmp/PromiseDrop-test/item-dead")

        let safe = PromiseDropSupport.dirsSafeToRemoveNow(
            allDirs: [pendingDir, deadDir],
            deliveredFiles: [],
            pendingDirs: [pendingDir]
        )

        XCTAssertEqual(safe, [deadDir], "a still-pending receiver dir must never be swept, even with an empty delivery")
    }

    func testDirsSafeToRemoveNowExcludesPendingDirsAlongsideDeliveredFiles() {
        let deliveredFile = URL(fileURLWithPath: "/tmp/PromiseDrop-test/item-a/Memo.m4a")
        let deliveredDir = URL(fileURLWithPath: "/tmp/PromiseDrop-test/item-a")
        let pendingDir = URL(fileURLWithPath: "/tmp/PromiseDrop-test/item-pending")
        let loserDir = URL(fileURLWithPath: "/tmp/PromiseDrop-test/item-loser")

        let safe = PromiseDropSupport.dirsSafeToRemoveNow(
            allDirs: [deliveredDir, pendingDir, loserDir],
            deliveredFiles: [deliveredFile],
            pendingDirs: [pendingDir]
        )

        XCTAssertEqual(safe, [loserDir])
    }

    func testDirsSafeToRemoveNowAllowsEverythingWhenNoPendingDirs() {
        let dirA = URL(fileURLWithPath: "/tmp/PromiseDrop-test/item-a")
        let dirB = URL(fileURLWithPath: "/tmp/PromiseDrop-test/item-b")

        let safe = PromiseDropSupport.dirsSafeToRemoveNow(allDirs: [dirA, dirB], deliveredFiles: [], pendingDirs: [])

        XCTAssertEqual(safe, [dirA, dirB])
    }

    // MARK: - Supported-file filtering for multi-file drops

    func testFilterKeepsDecodableAudioAndRejectsJunk() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.m4a"),
            URL(fileURLWithPath: "/tmp/b.txt"),
            URL(fileURLWithPath: "/tmp/c.wav"),
            URL(fileURLWithPath: "/tmp/d.pdf"),
        ]
        let kept = PromiseDropSupport.filterSupported(urls)
        XCTAssertEqual(kept.map(\.lastPathComponent), ["a.m4a", "c.wav"])
    }

    func testFilterAcceptsUppercaseExtensions() {
        let kept = PromiseDropSupport.filterSupported([URL(fileURLWithPath: "/tmp/MEMO.M4A")])
        XCTAssertEqual(kept.count, 1)
    }
}
