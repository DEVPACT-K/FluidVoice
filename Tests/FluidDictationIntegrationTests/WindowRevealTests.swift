import AppKit
@testable import FluidVoice_Debug
import XCTest

final class WindowRevealTests: XCTestCase {
    /// Regression: the main window could be stranded on another (even defunct) Space,
    /// where accessory-mode reveals succeeded invisibly. Every reveal must opt the
    /// window into collecting onto the user's active Space.
    @MainActor
    func testRevealOnActiveSpaceAdoptsMoveToActiveSpaceBehavior() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0

        let originalBehavior = window.collectionBehavior
        window.revealOnActiveSpace()

        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertEqual(window.alphaValue, 1)

        // The behavior is scoped to the reveal and restored on the next runloop pass.
        let restored = expectation(description: "collection behavior restored")
        DispatchQueue.main.async {
            XCTAssertEqual(window.collectionBehavior, originalBehavior)
            restored.fulfill()
        }
        wait(for: [restored], timeout: 2)
        window.close()
    }
}
