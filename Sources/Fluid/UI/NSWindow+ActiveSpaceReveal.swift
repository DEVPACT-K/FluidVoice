import AppKit

extension NSWindow {
    /// Reveal the window on the Space the user is currently viewing.
    ///
    /// The window server can leave the main window bound to another Space — including a
    /// defunct one left over from a previous session. When the app runs as an accessory
    /// (hidden from Dock and Cmd+Tab), the user has no way to travel to that Space, and a
    /// plain `orderFrontRegardless()` "succeeds" invisibly there. `.moveToActiveSpace`
    /// makes every reveal collect the window onto the active Space instead.
    func revealOnActiveSpace() {
        self.collectionBehavior.insert(.moveToActiveSpace)
        if self.alphaValue <= 0.01 {
            self.alphaValue = 1
        }
        self.orderFrontRegardless()
        self.makeKeyAndOrderFront(nil)
    }
}
