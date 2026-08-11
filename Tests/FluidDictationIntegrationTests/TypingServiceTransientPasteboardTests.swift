import AppKit
@testable import FluidVoice_Debug
import XCTest

// The temporary clipboard write used to drive synthetic Cmd+V must be tagged so clipboard
// managers exclude it from history. It is restored immediately and is not user-copied content.
final class TypingServiceTransientPasteboardTests: XCTestCase {
    func testTemporaryPasteboardDispatchDoesNotWaitForRestore() {
        let name = NSPasteboard.Name("com.fluidvoice.tests.nonblocking.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: name)
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        let startedAt = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(
            TypingService().withTemporaryPasteboardString(
                "dictation",
                pasteboard: pasteboard,
                restoreDelay: 0.25
            ) {
                XCTAssertEqual(pasteboard.string(forType: .string), "dictation")
                return true
            }
        )
        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - startedAt,
            0.1,
            "clipboard restoration must never hold the insertion worker open"
        )

        let restored = self.expectation(description: "original clipboard restored asynchronously")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            XCTAssertEqual(pasteboard.string(forType: .string), "original")
            restored.fulfill()
        }
        self.wait(for: [restored], timeout: 1)
    }

    func testRapidTemporaryPasteboardWritesRestoreOriginalWithoutBlocking() {
        let name = NSPasteboard.Name("com.fluidvoice.tests.rapid.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: name)
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let service = TypingService()

        XCTAssertTrue(service.withTemporaryPasteboardString("first", pasteboard: pasteboard, restoreDelay: 0.25) {
            true
        })
        XCTAssertTrue(service.withTemporaryPasteboardString("second", pasteboard: pasteboard, restoreDelay: 0.25) {
            XCTAssertEqual(pasteboard.string(forType: .string), "second")
            return true
        })

        let restored = self.expectation(description: "burst restores pre-burst clipboard")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            XCTAssertEqual(pasteboard.string(forType: .string), "original")
            restored.fulfill()
        }
        self.wait(for: [restored], timeout: 1)
    }

    func testExternalClipboardChangeIsNeverOverwrittenByDelayedRestore() {
        let name = NSPasteboard.Name("com.fluidvoice.tests.external.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: name)
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        XCTAssertTrue(
            TypingService().withTemporaryPasteboardString(
                "dictation",
                pasteboard: pasteboard,
                restoreDelay: 0.15
            ) { true }
        )
        pasteboard.clearContents()
        pasteboard.setString("user copied this", forType: .string)

        let retained = self.expectation(description: "external clipboard retained")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            XCTAssertEqual(pasteboard.string(forType: .string), "user copied this")
            retained.fulfill()
        }
        self.wait(for: [retained], timeout: 1)
    }

    func testExternalClipboardWriteOfSameTextIsNotMistakenForTemporaryWrite() {
        let name = NSPasteboard.Name("com.fluidvoice.tests.external-same-text.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: name)
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        XCTAssertTrue(
            TypingService().withTemporaryPasteboardString(
                "dictation",
                pasteboard: pasteboard,
                restoreDelay: 0.15
            ) { true }
        )
        pasteboard.clearContents()
        pasteboard.setString("dictation", forType: .string)

        let retained = self.expectation(description: "same-text external clipboard retained")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            XCTAssertEqual(pasteboard.string(forType: .string), "dictation")
            retained.fulfill()
        }
        self.wait(for: [retained], timeout: 1)
    }

    func testTerminationRestoresPendingTemporaryPasteboardImmediately() {
        let name = NSPasteboard.Name("com.fluidvoice.tests.termination.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: name)
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        XCTAssertTrue(
            TypingService().withTemporaryPasteboardString(
                "dictation",
                pasteboard: pasteboard,
                restoreDelay: 10
            ) { true }
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "dictation")

        TypingService.restorePendingPasteboardForTermination(pasteboard: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testTransientPasteboardItem_carriesText() {
        let item = TypingService.makeTransientPasteboardItem("hello world")
        XCTAssertEqual(
            item.string(forType: .string),
            "hello world",
            "the plain string must survive so paste and clipboard restore behave unchanged"
        )
    }

    func testTransientPasteboardItem_isMarkedForClipboardManagers() {
        let item = TypingService.makeTransientPasteboardItem("hello world")
        let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
        let types = item.types.map(\.rawValue)
        XCTAssertTrue(
            types.contains(transientType.rawValue),
            "temporary write must be marked Transient so clipboard managers skip it"
        )
        XCTAssertTrue(
            types.contains(autoGeneratedType.rawValue),
            "temporary write must be marked AutoGenerated so clipboard managers skip it"
        )
        XCTAssertEqual(
            item.data(forType: transientType)?.count,
            0
        )
        XCTAssertEqual(
            item.data(forType: autoGeneratedType)?.count,
            0
        )
    }

    func testTransientMarkersSurvivePasteboardWrite() throws {
        let name = NSPasteboard.Name("com.fluidvoice.tests.transient.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: name)
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.writeObjects([TypingService.makeTransientPasteboardItem("hello world")])
        )

        let item = try XCTUnwrap(pasteboard.pasteboardItems?.first)
        let types = item.types.map(\.rawValue)
        XCTAssertEqual(item.string(forType: .string), "hello world")
        XCTAssertTrue(types.contains("org.nspasteboard.TransientType"))
        XCTAssertTrue(types.contains("org.nspasteboard.AutoGeneratedType"))
    }

    func testTransientPasteboardItem_isNotMarkedConcealed() {
        let item = TypingService.makeTransientPasteboardItem("hello world")
        let types = item.types.map(\.rawValue)
        XCTAssertFalse(
            types.contains("org.nspasteboard.ConcealedType"),
            "ConcealedType signals sensitive content and must not be applied to a transcript"
        )
    }

    func testFocusRestoreDoesNotRaiseAllWindowsOfTargetApp() {
        // Issue #748: restoring focus after dictation must NOT raise every window of the
        // target app. `.activateAllWindows` brings forward all windows of the process and
        // destroys a multi-window layout (e.g. WebStorm) on every dictation.
        let options = TypingService.focusRestoreActivationOptions

        XCTAssertTrue(
            options.contains(.activateIgnoringOtherApps),
            "focus restore must still activate the target app and bring it forward"
        )
        XCTAssertFalse(
            options.contains(.activateAllWindows),
            "Restoring focus must not raise every window of the target app (issue #748)"
        )
    }
}
