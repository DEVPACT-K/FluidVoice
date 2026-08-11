import CoreGraphics
@testable import FluidVoice_Debug
import XCTest

// In-memory remembered-text-field fallback. These tests drive the resolver through a fake AX tree
// so the safety rules (foreground-app filtering, window filtering, secure-field exclusion,
// ambiguity, bounded traversal, and failed-focus refusal) are covered without a live AX session.
final class TextFieldTargetResolverTests: XCTestCase {
    // MARK: - Fake AX tree

    private final class FakeAXNode {
        var pid: pid_t
        var role: String?
        var subrole: String?
        var identifier: String?
        var runtimeIdentifier: String?
        var title: String?
        var elementDescription: String?
        var position: CGPoint?
        var valueSettable = true
        var protectedContent = false
        var exists = true
        var setFocusSucceeds = true
        var children: [FakeAXNode] = []
        weak var parentNode: FakeAXNode?

        init(pid: pid_t, role: String?) {
            self.pid = pid
            self.role = role
        }

        @discardableResult
        func add(_ child: FakeAXNode) -> FakeAXNode {
            child.parentNode = self
            self.children.append(child)
            return child
        }
    }

    private final class FakeAXClient: TextFieldAccessibilityClient {
        typealias Element = FakeAXNode

        var appRoots: [pid_t: FakeAXNode] = [:]
        var windowsByPID: [pid_t: FakeAXNode] = [:]
        var appIdentifiers: [pid_t: String] = [:]
        var livePIDs: Set<pid_t> = []
        var frontmostPID: pid_t?
        var focused: FakeAXNode?
        var setFocusCallCount = 0
        /// Simulates Chrome-style focus proxies: after a successful setFocused, the system-wide
        /// focused element reports as this node instead of the one we set.
        var postFocusOverride: FakeAXNode?

        func applicationElement(forPID pid: pid_t) -> FakeAXNode {
            if let root = self.appRoots[pid] { return root }
            let root = FakeAXNode(pid: pid, role: "AXApplication")
            self.appRoots[pid] = root
            return root
        }

        func systemFocusedElement() -> (element: FakeAXNode, pid: pid_t)? {
            guard let focused = self.focused, focused.exists else { return nil }
            return (focused, focused.pid)
        }

        func focusedWindow(forPID pid: pid_t) -> FakeAXNode? {
            self.windowsByPID[pid]
        }

        func frontmostApplicationPID() -> pid_t? {
            self.frontmostPID
        }

        func applicationExists(_ pid: pid_t) -> Bool {
            self.livePIDs.contains(pid)
        }

        func applicationIdentifier(forPID pid: pid_t) -> String? {
            self.appIdentifiers[pid]
        }

        func pid(of element: FakeAXNode) -> pid_t? {
            element.exists ? element.pid : nil
        }

        func role(of element: FakeAXNode) -> String? {
            element.exists ? element.role : nil
        }

        func subrole(of element: FakeAXNode) -> String? {
            element.exists ? element.subrole : nil
        }

        func identifier(of element: FakeAXNode) -> String? {
            element.identifier
        }

        func runtimeIdentifier(of element: FakeAXNode) -> String? {
            element.runtimeIdentifier
        }

        func title(of element: FakeAXNode) -> String? {
            element.title
        }

        func elementDescription(of element: FakeAXNode) -> String? {
            element.elementDescription
        }

        func position(of element: FakeAXNode) -> CGPoint? {
            element.position
        }

        func parent(of element: FakeAXNode) -> FakeAXNode? {
            element.parentNode
        }

        func children(of element: FakeAXNode, maxCount: Int) -> (elements: [FakeAXNode], wasTruncated: Bool) {
            guard element.exists else { return ([], false) }
            return (Array(element.children.prefix(maxCount)), element.children.count > maxCount)
        }

        func isSameElement(_ lhs: FakeAXNode, _ rhs: FakeAXNode) -> Bool {
            lhs === rhs
        }

        func isValueSettable(_ element: FakeAXNode) -> Bool {
            element.valueSettable
        }

        func isProtectedContent(_ element: FakeAXNode) -> Bool {
            element.protectedContent
        }

        func elementExists(_ element: FakeAXNode) -> Bool {
            element.exists && element.role != nil
        }

        @discardableResult
        func setFocused(_ element: FakeAXNode) -> Bool {
            self.setFocusCallCount += 1
            guard element.setFocusSucceeds else { return false }
            self.focused = self.postFocusOverride ?? element
            return true
        }

        @discardableResult
        func raiseAndFocusWindow(_ window: FakeAXNode, forPID pid: pid_t) -> Bool {
            guard window.pid == pid, window.exists else { return false }
            self.windowsByPID[pid] = window
            return true
        }

        func setMessagingTimeout(forPID _: pid_t, timeout _: Float) {}
    }

    private final class FakePersistence: TextFieldTargetHistoryPersistence {
        var storedHistory: PersistedTextFieldTargetHistory?
        var savedHistories: [PersistedTextFieldTargetHistory] = []
        var clearCount = 0
        var completesLoadImmediately = true
        private var pendingLoad: ((PersistedTextFieldTargetHistory?) -> Void)?
        private var pendingLoadedValue: PersistedTextFieldTargetHistory?

        init(storedHistory: PersistedTextFieldTargetHistory? = nil) {
            self.storedHistory = storedHistory
        }

        func load(completion: @escaping (PersistedTextFieldTargetHistory?) -> Void) {
            if self.completesLoadImmediately {
                completion(self.storedHistory)
            } else {
                self.pendingLoad = completion
                self.pendingLoadedValue = self.storedHistory
            }
        }

        func save(_ history: PersistedTextFieldTargetHistory) {
            self.storedHistory = history
            self.savedHistories.append(history)
        }

        func clear() {
            self.storedHistory = nil
            self.clearCount += 1
        }

        func flush() {}

        func completeLoad() {
            let completion = self.pendingLoad
            let loadedValue = self.pendingLoadedValue
            self.pendingLoad = nil
            self.pendingLoadedValue = nil
            completion?(loadedValue)
        }
    }

    // MARK: - Helpers

    private let appPID: pid_t = 4242
    private let otherPID: pid_t = 9999

    private var client: FakeAXClient!
    private var resolver: TextFieldTargetResolver<FakeAXClient>!
    private var clock: TimeInterval = 1000

    override func setUp() {
        super.setUp()
        self.client = FakeAXClient()
        self.installResolver()
        self.client.livePIDs = [self.appPID, self.otherPID]
        self.client.frontmostPID = self.appPID
        self.client.appIdentifiers = [self.appPID: "app", self.otherPID: "other-app"]
    }

    private func installResolver(
        persistence: TextFieldTargetHistoryPersistence? = nil,
        isEnabled: @escaping () -> Bool = { true }
    ) {
        self.resolver = TextFieldTargetResolver(
            client: self.client,
            persistence: persistence,
            isEnabled: isEnabled
        )
        self.resolver.now = { [unowned self] in self.clock }
        self.resolver.wallClockNow = { [unowned self] in self.clock }
        self.resolver.postWindowRaiseDelay = {}
        self.resolver.interFocusAttemptDelay = {}
    }

    override func tearDown() {
        self.resolver = nil
        self.client = nil
        super.tearDown()
    }

    private func makeWindow(pid: pid_t? = nil, identifier: String = "window") -> FakeAXNode {
        let window = FakeAXNode(pid: pid ?? self.appPID, role: "AXWindow")
        window.identifier = identifier
        window.position = CGPoint(x: 100, y: 100)
        let root = self.client.appRoots[window.pid] ?? self.client.applicationElement(forPID: window.pid)
        root.add(window)
        if self.client.windowsByPID[window.pid] == nil {
            self.client.windowsByPID[window.pid] = window
        }
        return window
    }

    private func makeField(
        in parent: FakeAXNode,
        identifier: String? = nil,
        role: String = "AXTextArea",
        title: String? = nil,
        x: CGFloat = 120,
        y: CGFloat = 140
    ) -> FakeAXNode {
        let container = parent.add(FakeAXNode(pid: parent.pid, role: "AXGroup"))
        container.identifier = "content"
        let scroll = container.add(FakeAXNode(pid: parent.pid, role: "AXScrollArea"))
        scroll.identifier = "scroller"
        let field = scroll.add(FakeAXNode(pid: parent.pid, role: role))
        field.identifier = identifier
        field.title = title
        field.position = CGPoint(x: x, y: y)
        return field
    }

    private func record(_ field: FakeAXNode, window: FakeAXNode?) {
        self.resolver.recordSuccessfulInsertion(element: field, pid: field.pid, window: window)
    }

    private func resolvedElement(forPID pid: pid_t? = nil) -> FakeAXNode? {
        switch self.resolver.resolveTarget(forPID: pid ?? self.appPID) {
        case let .current(element, _), let .remembered(element, _):
            return element
        case .noHistory, .refused:
            return nil
        }
    }

    // MARK: - Recording rules

    func testRecord_ignoresNonEditableAndSecureFields() {
        let window = self.makeWindow()
        let button = window.add(FakeAXNode(pid: self.appPID, role: "AXButton"))
        self.record(button, window: window)
        XCTAssertTrue(self.resolver.trackedFields(forPID: self.appPID).isEmpty)

        for role in ["AXGroup", "AXWebArea"] {
            let proxy = window.add(FakeAXNode(pid: self.appPID, role: role))
            self.record(proxy, window: window)
        }
        XCTAssertTrue(
            self.resolver.trackedFields(forPID: self.appPID).isEmpty,
            "broad web focus proxies must never be remembered as text fields"
        )

        let secure = self.makeField(in: window, identifier: "pwd", role: "AXSecureTextField")
        self.record(secure, window: window)
        XCTAssertTrue(self.resolver.trackedFields(forPID: self.appPID).isEmpty)

        let readOnly = self.makeField(in: window, identifier: "ro")
        readOnly.valueSettable = false
        self.record(readOnly, window: window)
        XCTAssertTrue(self.resolver.trackedFields(forPID: self.appPID).isEmpty)

        let protected = self.makeField(in: window, identifier: "protected")
        protected.protectedContent = true
        self.record(protected, window: window)
        XCTAssertTrue(self.resolver.trackedFields(forPID: self.appPID).isEmpty)
    }

    func testRecord_ignoresFluidItselfAndDeadApps() {
        let window = self.makeWindow()
        let own = FakeAXNode(pid: ProcessInfo.processInfo.processIdentifier, role: "AXTextField")
        self.record(own, window: window)
        XCTAssertTrue(self.resolver.trackedFields(forPID: ProcessInfo.processInfo.processIdentifier).isEmpty)

        let deadPID: pid_t = 55_555
        let deadField = FakeAXNode(pid: deadPID, role: "AXTextArea")
        self.record(deadField, window: nil)
        XCTAssertTrue(self.resolver.trackedFields(forPID: deadPID).isEmpty)
    }

    func testRecord_capsHistoryAtFiveFieldsPerApp() {
        let window = self.makeWindow()
        var fields: [FakeAXNode] = []
        for index in 0..<7 {
            let field = self.makeField(in: window, identifier: "f\(index)", x: 120 + CGFloat(index) * 50)
            fields.append(field)
            self.clock += 10
            self.record(field, window: window)
        }
        let tracked = self.resolver.trackedFields(forPID: self.appPID)
        XCTAssertEqual(tracked.count, 5)
        // Oldest two evicted; most recent five retained in recency order.
        XCTAssertEqual(tracked.map(\.fingerprint.identifier), ["f6", "f5", "f4", "f3", "f2"])
    }

    func testRecord_eachSuccessfulInsertionUpdatesRecencyAndFrequency() {
        let window = self.makeWindow()
        let field = self.makeField(in: window, identifier: "chat")
        self.record(field, window: window)
        self.clock += 0.2
        self.record(field, window: window)
        self.clock += 0.2
        self.record(field, window: window)
        let tracked = self.resolver.trackedFields(forPID: self.appPID)
        XCTAssertEqual(tracked.count, 1)
        XCTAssertEqual(tracked[0].useCount, 3)
        XCTAssertEqual(tracked[0].lastUsedAt, self.clock, accuracy: 0.001)

        self.clock += 5
        self.record(field, window: window)
        XCTAssertEqual(self.resolver.trackedFields(forPID: self.appPID)[0].useCount, 4)
    }

    func testRecord_sameUnidentifiedWebFieldWithPositionDriftDoesNotDuplicate() {
        let window = self.makeWindow()
        let first = self.makeField(in: window, x: 120, y: 140)
        first.elementDescription = "Message composer"
        self.record(first, window: window)

        self.clock += 1
        let rebuilt = self.makeField(in: window, x: 120, y: 163)
        rebuilt.elementDescription = "Message composer"
        self.record(rebuilt, window: window)

        let tracked = self.resolver.trackedFields(forPID: self.appPID)
        XCTAssertEqual(tracked.count, 1)
        XCTAssertEqual(tracked[0].useCount, 2)
        XCTAssertEqual(tracked[0].fingerprint.normalizedPosition?.y, 63)
    }

    func testRecord_distinctUnidentifiedWebFieldsRemainSeparate() {
        let window = self.makeWindow()
        let first = self.makeField(in: window, x: 120, y: 140)
        first.elementDescription = "Message composer"
        self.record(first, window: window)

        self.clock += 1
        let second = self.makeField(in: window, x: 120, y: 260)
        second.elementDescription = "Message composer"
        self.record(second, window: window)

        XCTAssertEqual(self.resolver.trackedFields(forPID: self.appPID).count, 2)
    }

    func testRecord_runtimeNodeIdentifierDeduplicatesRewrappedField() {
        let window = self.makeWindow()
        let first = self.makeField(in: window, x: 120, y: 140)
        first.runtimeIdentifier = "chrome:42"
        first.elementDescription = "Message composer"
        self.record(first, window: window)

        self.clock += 1
        let rewrapped = self.makeField(in: window, x: 500, y: 500)
        rewrapped.runtimeIdentifier = "chrome:42"
        rewrapped.elementDescription = "Rewrapped composer"
        self.record(rewrapped, window: window)

        let tracked = self.resolver.trackedFields(forPID: self.appPID)
        XCTAssertEqual(tracked.count, 1)
        XCTAssertEqual(tracked[0].useCount, 2)
        XCTAssertEqual(tracked[0].runtimeIdentifier, "chrome:42")
    }

    // MARK: - Resolution: current focus always wins

    func testResolve_currentlyFocusedEditableFieldWins() {
        let window = self.makeWindow()
        let remembered = self.makeField(in: window, identifier: "remembered")
        self.record(remembered, window: window)

        let active = self.makeField(in: window, identifier: "active", x: 400)
        self.client.focused = active

        XCTAssertTrue(self.resolvedElement() === active)
        XCTAssertTrue(self.client.focused === active, "resolver must never steal focus from an editable field")
        XCTAssertEqual(self.client.setFocusCallCount, 0)
    }

    func testResolve_nonEditableFocusEnablesFallback() {
        let window = self.makeWindow()
        self.client.windowsByPID[self.appPID] = window
        let remembered = self.makeField(in: window, identifier: "remembered")
        self.record(remembered, window: window)

        self.client.focused = window.add(FakeAXNode(pid: self.appPID, role: "AXButton"))

        let resolved = self.resolvedElement()
        XCTAssertTrue(resolved === remembered)
        XCTAssertTrue(self.client.focused === remembered)
        XCTAssertEqual(self.resolver.trackedFields(forPID: self.appPID)[0].useCount, 1)
    }

    func testResolve_noFocusAtAllEnablesFallback() {
        let window = self.makeWindow()
        let remembered = self.makeField(in: window, identifier: "remembered")
        self.record(remembered, window: window)
        self.client.windowsByPID[self.appPID] = window
        self.client.focused = nil

        XCTAssertTrue(self.resolvedElement() === remembered)
    }

    // MARK: - Resolution: filtering

    func testResolve_neverTargetsRememberedFieldInBackgroundApp() {
        let otherWindow = self.makeWindow(pid: self.otherPID, identifier: "other-window")
        let otherField = self.makeField(in: otherWindow, identifier: "other")
        self.record(otherField, window: otherWindow)

        guard case .refused = self.resolver.resolveTarget(forPID: self.otherPID) else {
            return XCTFail("background app must be refused")
        }
        XCTAssertFalse(self.client.focused === otherField)
        XCTAssertEqual(self.client.setFocusCallCount, 0)
    }

    func testResolve_filtersToCurrentWindow() {
        let windowA = self.makeWindow(identifier: "A")
        let windowB = self.makeWindow(identifier: "B")
        let fieldA = self.makeField(in: windowA, identifier: "field-a")
        let fieldB = self.makeField(in: windowB, identifier: "field-b")
        self.record(fieldA, window: windowA)
        self.clock += 10
        self.record(fieldB, window: windowB)

        self.client.windowsByPID[self.appPID] = windowA
        XCTAssertTrue(self.resolvedElement() === fieldA)
    }

    func testRecord_sameFieldIdentifierInTwoWindowsKeepsBothTargets() {
        let windowA = self.makeWindow(identifier: "A")
        let windowB = self.makeWindow(identifier: "B")
        let fieldA = self.makeField(in: windowA, identifier: "editor")
        let fieldB = self.makeField(in: windowB, identifier: "editor")
        self.record(fieldA, window: windowA)
        self.clock += 10
        self.record(fieldB, window: windowB)

        XCTAssertEqual(self.resolver.trackedFields(forPID: self.appPID).count, 2)
        self.client.windowsByPID[self.appPID] = windowA
        XCTAssertTrue(self.resolvedElement() === fieldA)
    }

    func testResolve_wrongWindowOnlyAborts() {
        let windowA = self.makeWindow(identifier: "A")
        let windowB = self.makeWindow(identifier: "B")
        let fieldB = self.makeField(in: windowB, identifier: "field-b")
        self.record(fieldB, window: windowB)

        self.client.windowsByPID[self.appPID] = windowA
        guard case .refused = self.resolver.resolveTarget(forPID: self.appPID) else {
            return XCTFail("history in another window must refuse insertion")
        }
        XCTAssertEqual(self.client.setFocusCallCount, 0)
    }

    func testResolve_noHistoryPreservesFirstUsePath() {
        _ = self.makeWindow()
        self.client.focused = FakeAXNode(pid: self.appPID, role: "AXButton")

        guard case .noHistory = self.resolver.resolveTarget(forPID: self.appPID) else {
            return XCTFail("first use without history must stay on the legacy path")
        }
    }

    func testResolve_appRelaunchUsesSameAppIdentityAndCurrentPID() {
        let oldWindow = self.makeWindow(identifier: "document")
        let oldField = self.makeField(in: oldWindow, identifier: "editor", title: "Message")
        self.record(oldField, window: oldWindow)

        oldField.exists = false
        oldWindow.exists = false
        self.client.livePIDs.remove(self.appPID)

        let relaunchedPID: pid_t = 4243
        self.client.livePIDs.insert(relaunchedPID)
        self.client.appIdentifiers[relaunchedPID] = "app"
        self.client.frontmostPID = relaunchedPID
        let newWindow = self.makeWindow(pid: relaunchedPID, identifier: "document")
        let newField = self.makeField(in: newWindow, identifier: "editor", title: "Message")
        self.client.windowsByPID[relaunchedPID] = newWindow

        XCTAssertTrue(self.resolvedElement(forPID: relaunchedPID) === newField)
        XCTAssertEqual(self.client.focused?.pid, relaunchedPID)
    }

    // MARK: - Resolution: ordering

    func testResolve_recencyBeatsFrequency() {
        let window = self.makeWindow()
        let frequent = self.makeField(in: window, identifier: "frequent")
        let recent = self.makeField(in: window, identifier: "recent", x: 400)

        for _ in 0..<3 {
            self.record(frequent, window: window)
            self.clock += 5
        }
        self.record(recent, window: window)

        self.resolver.budget.maxCandidates = 1
        XCTAssertTrue(self.resolvedElement() === recent)
    }

    func testResolve_frequencyBreaksEqualRecency() {
        let window = self.makeWindow()
        let frequent = self.makeField(in: window, identifier: "frequent")
        let rare = self.makeField(in: window, identifier: "rare", x: 400)

        self.record(frequent, window: window)
        self.clock += 5
        self.record(frequent, window: window) // useCount 2
        // Rare recorded at the same timestamp as frequent's last use: equal recency.
        self.record(rare, window: window)

        XCTAssertEqual(
            self.resolver.trackedFields(forPID: self.appPID).map(\.fingerprint.identifier),
            ["frequent", "rare"],
            "equal recency must fall back to frequency ordering"
        )
    }

    // MARK: - Resolution: stale live reference re-walk

    func testResolve_staleLiveReferenceTriggersTargetedReWalk() {
        let window = self.makeWindow()
        let recorded = self.makeField(in: window, identifier: "chat", title: "Message")
        self.record(recorded, window: window)

        // App rebuilt its tree: recorded element is dead, replacement matches the fingerprint.
        recorded.exists = false
        let rebuilt = self.makeField(in: window, identifier: "chat", title: "Message")

        let resolved = self.resolvedElement()
        XCTAssertTrue(resolved === rebuilt, "targeted walk should find the rebuilt field by fingerprint")
        XCTAssertTrue(self.client.focused === rebuilt)
    }

    func testResolve_reWalkRejectsDifferentIdentifier() {
        let window = self.makeWindow()
        let recorded = self.makeField(in: window, identifier: "chat")
        self.record(recorded, window: window)
        recorded.exists = false
        _ = self.makeField(in: window, identifier: "search")

        XCTAssertNil(self.resolvedElement())
        XCTAssertEqual(self.client.setFocusCallCount, 0)
    }

    func testResolve_ambiguousMatchAborts() {
        let window = self.makeWindow()
        let recorded = self.makeField(in: window, identifier: nil, title: "Message", x: 120, y: 140)
        self.record(recorded, window: window)
        recorded.exists = false

        // Two structurally identical candidates at nearly the same position: cannot disambiguate.
        _ = self.makeField(in: window, identifier: nil, title: "Message", x: 121, y: 141)
        _ = self.makeField(in: window, identifier: nil, title: "Message", x: 122, y: 142)

        XCTAssertNil(self.resolvedElement())
        XCTAssertEqual(self.client.setFocusCallCount, 0, "ambiguity must abort before any focus attempt")
    }

    // MARK: - Resolution: failure means no focus change

    func testResolve_focusSetFailureAborts() {
        let window = self.makeWindow()
        let field = self.makeField(in: window, identifier: "chat")
        field.setFocusSucceeds = false
        self.record(field, window: window)

        XCTAssertNil(self.resolvedElement())
        XCTAssertFalse(self.client.focused === field)
    }

    func testResolve_semanticPostFocusMismatchAborts() {
        let window = self.makeWindow()
        let recorded = self.makeField(in: window, identifier: "chat")
        self.record(recorded, window: window)

        // setFocused reports success, but system focus lands on a non-editable label.
        self.client.postFocusOverride = window.add(FakeAXNode(pid: self.appPID, role: "AXStaticText"))

        XCTAssertNil(self.resolvedElement())
    }

    func testResolve_equivalentRoleFocusProxyIsAccepted() {
        let window = self.makeWindow()
        let recorded = self.makeField(in: window, identifier: "chat")
        self.record(recorded, window: window)

        // Chrome/Electron hand back a *different* element for the same visual field after
        // activation. The broad proxy may verify a successful focus operation, but it is never
        // itself captured or persisted as the target.
        let proxy = FakeAXNode(pid: self.appPID, role: "AXWebArea")
        proxy.valueSettable = false
        self.client.postFocusOverride = proxy

        XCTAssertTrue(self.resolvedElement() === recorded)
        XCTAssertTrue(self.client.focused === proxy)
    }

    func testResolve_webPageProxyDoesNotBypassRememberedFieldFocus() {
        let window = self.makeWindow()
        let recorded = self.makeField(in: window, identifier: "composer")
        self.record(recorded, window: window)

        let page = window.add(FakeAXNode(pid: self.appPID, role: "AXWebArea"))
        page.valueSettable = false
        self.client.focused = page

        XCTAssertTrue(self.resolvedElement() === recorded)
        XCTAssertTrue(self.client.focused === recorded)
        XCTAssertEqual(self.client.setFocusCallCount, 1)
    }

    func testResolve_webProxyCannotVerifyWhenRememberedFieldRejectedFocus() {
        let window = self.makeWindow()
        let recorded = self.makeField(in: window, identifier: "composer")
        recorded.setFocusSucceeds = false
        self.record(recorded, window: window)

        let page = window.add(FakeAXNode(pid: self.appPID, role: "AXWebArea"))
        page.valueSettable = false
        self.client.focused = page

        XCTAssertNil(self.resolvedElement())
        XCTAssertTrue(self.client.focused === page)
    }

    func testResolve_differentAppFocusAfterSetAborts() {
        let window = self.makeWindow()
        let recorded = self.makeField(in: window, identifier: "chat")
        self.record(recorded, window: window)

        // Focus bounced to another app entirely: never type.
        self.client.postFocusOverride = FakeAXNode(pid: self.otherPID, role: "AXTextArea")

        XCTAssertNil(self.resolvedElement())
    }

    func testResolve_secureCurrentFocusRefusesWithoutChangingFocus() {
        let window = self.makeWindow()
        let remembered = self.makeField(in: window, identifier: "chat")
        self.record(remembered, window: window)
        let secure = window.add(FakeAXNode(pid: self.appPID, role: "AXSecureTextField"))
        self.client.focused = secure

        guard case .refused = self.resolver.resolveTarget(forPID: self.appPID) else {
            return XCTFail("secure focus must refuse insertion")
        }
        XCTAssertTrue(self.client.focused === secure)
        XCTAssertEqual(self.client.setFocusCallCount, 0)
    }

    // MARK: - Captured focus integration

    func testRestoreCapturedFocus_currentEditableFieldStillWins() {
        let window = self.makeWindow()
        let captured = self.makeField(in: window, identifier: "captured")
        self.client.focused = captured
        XCTAssertEqual(self.resolver.captureSystemFocus(), self.appPID)

        let newlyFocused = self.makeField(in: window, identifier: "new", x: 400)
        self.client.focused = newlyFocused

        XCTAssertTrue(self.resolver.restoreCapturedFocus(forPID: self.appPID))
        XCTAssertTrue(self.client.focused === newlyFocused)
        XCTAssertEqual(self.client.setFocusCallCount, 0)
    }

    func testRestoreCapturedFocus_usesCapturedLiveReferenceBeforeHistory() {
        let window = self.makeWindow()
        let remembered = self.makeField(in: window, identifier: "remembered")
        self.record(remembered, window: window)
        let captured = self.makeField(in: window, identifier: "captured", x: 400)
        self.client.focused = captured
        XCTAssertEqual(self.resolver.captureSystemFocus(), self.appPID)

        self.client.focused = FakeAXNode(pid: self.otherPID, role: "AXButton")
        XCTAssertTrue(self.resolver.restoreCapturedFocus(forPID: self.appPID))
        XCTAssertTrue(self.client.focused === captured)
    }

    func testCapturedFocus_samePIDDifferentEditableFieldIsNotStillActive() {
        let window = self.makeWindow()
        let captured = self.makeField(in: window, identifier: "captured")
        self.client.focused = captured
        XCTAssertEqual(self.resolver.captureSystemFocus(), self.appPID)

        self.client.focused = self.makeField(in: window, identifier: "different", x: 400)

        XCTAssertFalse(self.resolver.isCapturedFocusStillActive(forPID: self.appPID))
    }

    func testCapturedFocus_samePIDWebProxyIsNotStillActive() {
        let window = self.makeWindow()
        let captured = self.makeField(in: window, identifier: "captured")
        self.client.focused = captured
        XCTAssertEqual(self.resolver.captureSystemFocus(), self.appPID)

        self.client.focused = window.add(FakeAXNode(pid: self.appPID, role: "AXGroup"))

        XCTAssertFalse(self.resolver.isCapturedFocusStillActive(forPID: self.appPID))
    }

    func testCapturedFocus_rebuiltEquivalentWebFieldIsStillActive() {
        let window = self.makeWindow()
        let captured = self.makeField(in: window, x: 120, y: 140)
        captured.elementDescription = "Message composer"
        self.client.focused = captured
        XCTAssertEqual(self.resolver.captureSystemFocus(), self.appPID)

        let rebuilt = self.makeField(in: window, x: 120, y: 163)
        rebuilt.elementDescription = "Message composer"
        self.client.focused = rebuilt

        XCTAssertTrue(self.resolver.isCapturedFocusStillActive(forPID: self.appPID))
    }

    func testCapturedFocus_runtimeNodeIdentifierRecognizesExactRewrappedField() {
        let window = self.makeWindow()
        let captured = self.makeField(in: window, x: 120, y: 140)
        captured.runtimeIdentifier = "chrome:42"
        self.client.focused = captured
        XCTAssertEqual(self.resolver.captureSystemFocus(), self.appPID)

        let rewrapped = self.makeField(in: window, x: 500, y: 500)
        rewrapped.runtimeIdentifier = "chrome:42"
        self.client.focused = rewrapped

        XCTAssertTrue(self.resolver.isCapturedFocusStillActive(forPID: self.appPID))
    }

    func testRestoreCapturedFocus_proxyCannotVerifyRejectedFocusRequest() {
        let window = self.makeWindow()
        let captured = self.makeField(in: window, identifier: "captured")
        self.client.focused = captured
        XCTAssertEqual(self.resolver.captureSystemFocus(), self.appPID)
        captured.setFocusSucceeds = false

        self.client.focused = window.add(FakeAXNode(pid: self.appPID, role: "AXGroup"))

        XCTAssertFalse(self.resolver.restoreCapturedFocus(forPID: self.appPID))
    }

    // MARK: - Resolution: budgets

    func testResolve_visitedNodeBudgetExhaustionAborts() {
        let window = self.makeWindow()
        let recorded = self.makeField(in: window, identifier: "chat")
        self.record(recorded, window: window)
        recorded.exists = false

        // A matching rebuilt field exists, but a flood of non-matching nodes exhausts the
        // visited-node budget before the walk reaches it (flood is explored first by the DFS).
        for index in 0..<400 {
            let group = FakeAXNode(pid: self.appPID, role: "AXGroup")
            group.identifier = "flood\(index)"
            window.add(group)
        }
        _ = self.makeField(in: window, identifier: "chat")
        // DFS explores the last child first, so the flood (appended last) is walked before the
        // content groups that hold the matching rebuilt field.
        self.resolver.budget.maxVisitedNodes = 20

        XCTAssertNil(self.resolvedElement())
    }

    func testResolve_totalTimeBudgetExhaustionAborts() {
        let window = self.makeWindow()
        let recorded = self.makeField(in: window, identifier: "chat")
        self.record(recorded, window: window)
        recorded.exists = false

        // Clock jumps far past the total budget on every read after the first.
        var reads = 0
        self.resolver.now = { [unowned self] in
            reads += 1
            return reads > 2 ? self.clock + 100 : self.clock
        }

        XCTAssertNil(self.resolvedElement())
    }

    func testResolve_timeAdvanceDuringFocusAttemptsIsBounded() {
        let window = self.makeWindow()
        let field = self.makeField(in: window, identifier: "chat")
        field.setFocusSucceeds = false
        self.record(field, window: window)
        self.resolver.maxFocusAttempts = 3

        XCTAssertNil(self.resolvedElement())
        XCTAssertLessThanOrEqual(self.client.setFocusCallCount, 4, "focus attempts must be bounded")
    }

    // MARK: - Resolution: secure fields never resolved

    func testResolve_secureFieldInTreeIsSkippedDuringReWalk() {
        let window = self.makeWindow()
        let recorded = self.makeField(in: window, identifier: "chat", title: "Message")
        self.record(recorded, window: window)
        recorded.exists = false

        // A secure field wearing a similar structure must not be matched.
        let secure = self.makeField(in: window, identifier: nil, role: "AXSecureTextField", title: "Message")
        XCTAssertNil(self.resolvedElement())
        XCTAssertFalse(self.client.focused === secure)
    }

    // MARK: - Persistence

    func testPersistence_restartRevalidatesMatchingFieldAndKeepsLifetimeCount() {
        let persistence = FakePersistence()
        self.installResolver(persistence: persistence)
        let originalWindow = self.makeWindow(identifier: "document")
        let originalField = self.makeField(in: originalWindow, identifier: "editor", title: "Message")
        self.record(originalField, window: originalWindow)
        XCTAssertEqual(persistence.storedHistory?.apps.first?.fields.first?.useCount, 1)

        self.client = FakeAXClient()
        self.client.livePIDs = [self.appPID]
        self.client.frontmostPID = self.appPID
        self.client.appIdentifiers = [self.appPID: "app"]
        self.installResolver(persistence: persistence)
        let relaunchedWindow = self.makeWindow(identifier: "document")
        let relaunchedField = self.makeField(in: relaunchedWindow, identifier: "editor", title: "Message")
        self.client.focused = relaunchedWindow.add(FakeAXNode(pid: self.appPID, role: "AXButton"))

        XCTAssertTrue(self.resolvedElement() === relaunchedField)
        XCTAssertEqual(self.resolver.trackedFields(forPID: self.appPID).count, 1)
        self.record(relaunchedField, window: relaunchedWindow)
        XCTAssertEqual(self.resolver.trackedFields(forPID: self.appPID)[0].useCount, 2)
        XCTAssertEqual(persistence.storedHistory?.apps.first?.fields.first?.useCount, 2)
    }

    func testPersistence_completeNoMatchRemovesConfirmedStaleField() {
        let persistence = FakePersistence()
        self.installResolver(persistence: persistence)
        let originalWindow = self.makeWindow(identifier: "document")
        let originalField = self.makeField(in: originalWindow, identifier: "removed-editor")
        self.record(originalField, window: originalWindow)

        self.client = FakeAXClient()
        self.client.livePIDs = [self.appPID]
        self.client.frontmostPID = self.appPID
        self.client.appIdentifiers = [self.appPID: "app"]
        self.installResolver(persistence: persistence)
        let relaunchedWindow = self.makeWindow(identifier: "document")
        self.client.focused = relaunchedWindow.add(FakeAXNode(pid: self.appPID, role: "AXButton"))

        guard case .refused = self.resolver.resolveTarget(forPID: self.appPID) else {
            return XCTFail("a confirmed-stale persisted field must not resolve")
        }
        XCTAssertTrue(self.resolver.trackedFields(forPID: self.appPID).isEmpty)
        XCTAssertTrue(persistence.storedHistory?.apps.isEmpty == true)
    }

    func testPersistence_incompleteValidationKeepsEntryForLaterRetry() {
        let persistence = FakePersistence()
        self.installResolver(persistence: persistence)
        let window = self.makeWindow(identifier: "document")
        let field = self.makeField(in: window, identifier: "editor")
        self.record(field, window: window)
        field.exists = false
        for index in 0..<40 {
            window.add(FakeAXNode(pid: self.appPID, role: "AXGroup")).identifier = "flood\(index)"
        }
        self.resolver.budget.maxVisitedNodes = 5

        XCTAssertNil(self.resolvedElement())
        XCTAssertEqual(self.resolver.trackedFields(forPID: self.appPID).count, 1)
        XCTAssertEqual(persistence.storedHistory?.apps.first?.fields.count, 1)
    }

    func testPersistence_delayedLoadMergesEarlyCaptureWithoutDuplicates() {
        let sourcePersistence = FakePersistence()
        self.installResolver(persistence: sourcePersistence)
        let sourceWindow = self.makeWindow(identifier: "document")
        let sourceField = self.makeField(in: sourceWindow, identifier: "editor")
        for _ in 0..<3 {
            self.record(sourceField, window: sourceWindow)
            self.clock += 1
        }
        let delayedPersistence = FakePersistence(storedHistory: sourcePersistence.storedHistory)
        delayedPersistence.completesLoadImmediately = false

        self.client = FakeAXClient()
        self.client.livePIDs = [self.appPID]
        self.client.frontmostPID = self.appPID
        self.client.appIdentifiers = [self.appPID: "app"]
        let currentWindow = self.makeWindow(identifier: "document")
        let currentField = self.makeField(in: currentWindow, identifier: "editor")
        self.installResolver(persistence: delayedPersistence)
        self.record(currentField, window: currentWindow)
        delayedPersistence.completeLoad()

        let fields = self.resolver.trackedFields(forPID: self.appPID)
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[0].useCount, 4)
        XCTAssertEqual(delayedPersistence.storedHistory?.apps.first?.fields.count, 1)
        XCTAssertEqual(delayedPersistence.storedHistory?.apps.first?.fields.first?.useCount, 4)
    }

    func testPersistence_duplicateStoredKeysCollapseWithoutInflatingFrequency() {
        let sourcePersistence = FakePersistence()
        self.installResolver(persistence: sourcePersistence)
        let window = self.makeWindow(identifier: "document")
        let field = self.makeField(in: window, identifier: "editor")
        self.record(field, window: window)
        guard var stored = sourcePersistence.storedHistory,
              var duplicate = stored.apps.first?.fields.first
        else {
            return XCTFail("expected persisted field")
        }
        duplicate.useCount = 9
        duplicate.lastUsedAt += 20
        if var position = duplicate.fingerprint.normalizedPosition {
            position.y += 20
            duplicate.fingerprint.normalizedPosition = position
        }
        stored.apps[0].fields.append(duplicate)
        let persistence = FakePersistence(storedHistory: stored)

        self.installResolver(persistence: persistence)

        let fields = self.resolver.trackedFields(forPID: self.appPID)
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[0].useCount, 9)
        XCTAssertEqual(persistence.storedHistory?.apps.first?.fields.count, 1)
    }

    func testPersistence_clearDuringLoadPreventsHistoryResurrection() {
        let sourcePersistence = FakePersistence()
        self.installResolver(persistence: sourcePersistence)
        let window = self.makeWindow(identifier: "document")
        self.record(self.makeField(in: window, identifier: "editor"), window: window)
        let delayedPersistence = FakePersistence(storedHistory: sourcePersistence.storedHistory)
        delayedPersistence.completesLoadImmediately = false

        self.installResolver(persistence: delayedPersistence)
        self.resolver.clearHistory()
        delayedPersistence.completeLoad()

        XCTAssertTrue(self.resolver.trackedFields(forPID: self.appPID).isEmpty)
        XCTAssertNil(delayedPersistence.storedHistory)
        XCTAssertGreaterThanOrEqual(delayedPersistence.clearCount, 1)
    }

    func testPersistence_recordAfterClearDuringLoadSurvivesStaleLoad() {
        let sourcePersistence = FakePersistence()
        self.installResolver(persistence: sourcePersistence)
        let oldWindow = self.makeWindow(identifier: "old-document")
        self.record(self.makeField(in: oldWindow, identifier: "old-editor"), window: oldWindow)
        let delayedPersistence = FakePersistence(storedHistory: sourcePersistence.storedHistory)
        delayedPersistence.completesLoadImmediately = false

        self.installResolver(persistence: delayedPersistence)
        self.resolver.clearHistory()
        let newWindow = self.makeWindow(identifier: "new-document")
        let newField = self.makeField(in: newWindow, identifier: "new-editor")
        self.record(newField, window: newWindow)
        delayedPersistence.completeLoad()

        let fields = self.resolver.trackedFields(forPID: self.appPID)
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[0].fingerprint.identifier, "new-editor")
        XCTAssertEqual(fields[0].useCount, 1)
        XCTAssertEqual(delayedPersistence.storedHistory?.apps.first?.fields.count, 1)
        XCTAssertEqual(delayedPersistence.storedHistory?.apps.first?.fields.first?.fingerprint.identifier, "new-editor")
    }

    func testPersistence_disabledFeatureClearsAndRefusesToCapture() {
        let sourcePersistence = FakePersistence()
        self.installResolver(persistence: sourcePersistence)
        let window = self.makeWindow(identifier: "document")
        let field = self.makeField(in: window, identifier: "editor")
        self.record(field, window: window)
        let persistence = FakePersistence(storedHistory: sourcePersistence.storedHistory)
        var enabled = false

        self.installResolver(persistence: persistence, isEnabled: { enabled })
        self.record(field, window: window)
        guard case .noHistory = self.resolver.resolveTarget(forPID: self.appPID) else {
            return XCTFail("disabled history must preserve the legacy insertion path")
        }
        XCTAssertTrue(self.resolver.trackedFields(forPID: self.appPID).isEmpty)
        XCTAssertNil(persistence.storedHistory)

        enabled = true
        self.record(field, window: window)
        XCTAssertEqual(self.resolver.trackedFields(forPID: self.appPID).count, 1)
    }

    func testPersistence_replacesOldFieldsAndAppsAtConfiguredBounds() {
        let persistence = FakePersistence()
        self.installResolver(persistence: persistence)
        let firstWindow = self.makeWindow(identifier: "first-window")
        for index in 0..<7 {
            self.clock += 1
            self.record(self.makeField(in: firstWindow, identifier: "field-\(index)"), window: firstWindow)
        }
        XCTAssertEqual(persistence.storedHistory?.apps.first?.fields.count, 5)
        XCTAssertEqual(
            persistence.storedHistory?.apps.first?.fields.compactMap(\.fingerprint.identifier),
            ["field-6", "field-5", "field-4", "field-3", "field-2"]
        )

        for index in 0..<21 {
            let pid = pid_t(5000 + index)
            self.client.livePIDs.insert(pid)
            self.client.appIdentifiers[pid] = "bounded-app-\(index)"
            let window = self.makeWindow(pid: pid, identifier: "window-\(index)")
            self.clock += 1
            self.record(self.makeField(in: window, identifier: "editor"), window: window)
        }
        let identifiers = persistence.storedHistory?.apps.map(\.applicationIdentifier) ?? []
        XCTAssertEqual(identifiers.count, 20)
        XCTAssertFalse(identifiers.contains("app"))
        XCTAssertFalse(identifiers.contains("bounded-app-0"))
        XCTAssertTrue(identifiers.contains("bounded-app-20"))
    }

    func testFilePersistence_corruptPayloadIsRemoved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextFieldTargetResolverTests.\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent(FileTextFieldHistoryStore.fileName)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: fileURL)
        let persistence = FileTextFieldHistoryStore(fileURL: fileURL)
        let loaded = expectation(description: "corrupt history load completes")

        persistence.load { history in
            XCTAssertNil(history)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
            loaded.fulfill()
        }

        self.wait(for: [loaded], timeout: 2)
    }

    func testFilePersistence_roundTripsFingerprintHistory() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextFieldTargetResolverTests.\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent(FileTextFieldHistoryStore.fileName)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourcePersistence = FakePersistence()
        self.installResolver(persistence: sourcePersistence)
        let window = self.makeWindow(identifier: "document")
        self.record(self.makeField(in: window, identifier: "editor", title: "Message"), window: window)
        guard let expected = sourcePersistence.storedHistory else {
            return XCTFail("expected persisted field")
        }
        let persistence = FileTextFieldHistoryStore(fileURL: fileURL)
        let loaded = expectation(description: "history round trip completes")

        persistence.save(expected)
        persistence.load { history in
            XCTAssertEqual(history, expected)
            loaded.fulfill()
        }

        self.wait(for: [loaded], timeout: 2)
    }
}
