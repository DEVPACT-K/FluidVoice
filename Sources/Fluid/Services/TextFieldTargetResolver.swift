import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Remembers a small, bounded, per-app history of editable text fields the user dictated into.
// When insertion-time focus lands on a non-editable element (or focus capture failed entirely),
// the resolver can re-focus a remembered field instead of guessing at the first text-looking
// element in the AX tree. Safety rules:
//   - A currently focused editable field always wins; the resolver never steals that focus.
//   - Resolution is bounded (depth, visited nodes, wall time) and any failure, ambiguity,
//     timeout, or secure field results in doing nothing.
//   - Only fingerprints and ranking persist; live AX references, PIDs, and text content never do.
//
// All AX access goes through `TextFieldAccessibilityClient` so the safety rules are unit-testable
// with a fake tree.

/// Abstraction over the Accessibility API used by `TextFieldTargetResolver`.
protocol TextFieldAccessibilityClient {
    associatedtype Element: AnyObject

    func applicationElement(forPID pid: pid_t) -> Element
    func systemFocusedElement() -> (element: Element, pid: pid_t)?
    func focusedWindow(forPID pid: pid_t) -> Element?
    func frontmostApplicationPID() -> pid_t?
    func applicationExists(_ pid: pid_t) -> Bool
    func applicationIdentifier(forPID pid: pid_t) -> String?

    func pid(of element: Element) -> pid_t?
    func role(of element: Element) -> String?
    func subrole(of element: Element) -> String?
    func identifier(of element: Element) -> String?
    func runtimeIdentifier(of element: Element) -> String?
    func title(of element: Element) -> String?
    func elementDescription(of element: Element) -> String?
    func position(of element: Element) -> CGPoint?
    func parent(of element: Element) -> Element?
    func children(of element: Element, maxCount: Int) -> (elements: [Element], wasTruncated: Bool)

    /// Identity comparison (CFEqual for AXUIElement). May fail across re-fetch in Chrome/Electron,
    /// so verification never relies on this alone.
    func isSameElement(_ lhs: Element, _ rhs: Element) -> Bool
    func isValueSettable(_ element: Element) -> Bool
    func isProtectedContent(_ element: Element) -> Bool
    /// Cheap liveness probe: the element still resolves in its owning process.
    func elementExists(_ element: Element) -> Bool
    @discardableResult func setFocused(_ element: Element) -> Bool
    @discardableResult func raiseAndFocusWindow(_ window: Element, forPID pid: pid_t) -> Bool
    /// Bounds per-call AX messaging latency for the target app during traversal. No-op in tests.
    func setMessagingTimeout(forPID pid: pid_t, timeout: Float)
}

// MARK: - Fingerprint

/// Persistable-in-memory description of a text field. `AXUIElement` itself cannot be persisted,
/// so re-resolution after the live reference dies uses this fingerprint in a targeted tree walk.
/// Position is the weakest component (window moves/resizes/scrolls shift it) and is only ever a
/// tiebreaker; identifier and parent path dominate.
nonisolated struct TextFieldFingerprint: Codable, Equatable {
    var role: String
    var subrole: String?
    var identifier: String?
    var title: String?
    var elementDescription: String?
    /// Up to 4 ancestors, nearest first, as "role" or "role#identifier".
    var parentPath: [String]
    /// Position relative to the owning window origin; tiebreaker only.
    var normalizedPosition: CGPoint?
}

nonisolated struct TextFieldWindowFingerprint: Codable, Equatable {
    var identifier: String?
    var title: String?
}

// MARK: - Tracked field

struct TrackedTextField<Element: AnyObject> {
    var element: Element?
    var pid: pid_t?
    /// Exact per-process node identity (for example Chromium's accessibility node ID). Never persisted.
    var runtimeIdentifier: String?
    var window: Element?
    var windowFingerprint: TextFieldWindowFingerprint?
    var fingerprint: TextFieldFingerprint
    var lastUsedAt: TimeInterval
    var useCount: Int
}

// MARK: - Resolver

final class TextFieldTargetResolver<Client: TextFieldAccessibilityClient> {
    enum Resolution {
        case current(Client.Element, window: Client.Element?)
        case remembered(Client.Element, window: Client.Element?)
        case noHistory
        case refused
    }

    private struct FocusSnapshot {
        let pid: pid_t
        let window: Client.Element?
        let element: Client.Element
        let fingerprint: TextFieldFingerprint?
        let runtimeIdentifier: String?
    }

    struct ResolutionBudget {
        var maxDepth = 8
        var maxVisitedNodes = 250
        var maxCandidates = 5
        /// Per-candidate targeted tree walk cap.
        var traversalTimeLimit: TimeInterval = 0.15
        /// Whole-resolution cap across candidates.
        var totalTimeLimit: TimeInterval = 0.5
    }

    private struct ScoredMatch {
        let element: Client.Element
        let score: Int
        let positionDistance: CGFloat
    }

    private enum FingerprintLookup {
        case match(Client.Element)
        case notFound
        case indeterminate
    }

    /// Roles that are safe to target and persist as actual text fields. Broad web containers are
    /// deliberately excluded: Safari/Chrome may report them after focus changes, but they are not
    /// themselves reliable insertion targets.
    static var editableRoles: Set<String> {
        [
            "AXTextField",
            "AXTextArea",
            "AXSearchField",
            "AXComboBox",
        ]
    }

    /// Chrome/Electron/Safari can hand back one of these after a real text field accepted focus.
    /// They may verify that focus transition, but must never enter history as fields themselves.
    private static var focusProxyRoles: Set<String> {
        ["AXWebArea", "AXGroup"]
    }

    private let client: Client
    private let persistence: TextFieldTargetHistoryPersistence?
    private let isEnabled: () -> Bool
    private let lock = NSLock()
    private var history: [String: [TrackedTextField<Client.Element>]] = [:]
    /// LRU order of tracked apps, most recently used first.
    private var appOrder: [String] = []
    private var focusSnapshot: FocusSnapshot?
    private var persistenceLoaded = false
    private var historyChangedBeforeLoad = false
    private var clearedBeforeLoad = false

    var budget = ResolutionBudget()
    var maxFieldsPerApp = 5
    var maxTrackedApps = 20
    var maxFocusAttempts = 3

    /// Injected for tests.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var wallClockNow: () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    var postWindowRaiseDelay: () -> Void = { usleep(40_000) }
    var interFocusAttemptDelay: () -> Void = { usleep(50_000) }
    var log: (String) -> Void = { _ in }

    init(
        client: Client,
        persistence: TextFieldTargetHistoryPersistence? = nil,
        isEnabled: @escaping () -> Bool = { true }
    ) {
        self.client = client
        self.persistence = persistence
        self.isEnabled = isEnabled
        guard let persistence else {
            self.persistenceLoaded = true
            return
        }
        persistence.load { [weak self] persistedHistory in
            self?.finishLoadingPersistence(persistedHistory)
        }
    }

    // MARK: - Captured focus

    /// Replaces TypingService's former parallel focus snapshot. The fingerprint is used only to
    /// recognize the exact captured field when web apps recreate its AXUIElement wrapper.
    func captureSystemFocus() -> pid_t? {
        guard let focused = self.client.systemFocusedElement(), focused.pid > 0 else {
            self.withLock { self.focusSnapshot = nil }
            return nil
        }
        let window = self.client.focusedWindow(forPID: focused.pid)
        let fingerprint = self.isEditableField(focused.element) && !self.isSecureField(focused.element)
            ? self.fingerprint(of: focused.element, window: window)
            : nil
        self.withLock {
            self.focusSnapshot = FocusSnapshot(
                pid: focused.pid,
                window: window,
                element: focused.element,
                fingerprint: fingerprint,
                runtimeIdentifier: self.client.runtimeIdentifier(of: focused.element)
            )
        }
        return focused.pid
    }

    func systemFocusedPID() -> pid_t? {
        self.client.systemFocusedElement()?.pid
    }

    func isCapturedFocusStillActive(forPID pid: pid_t) -> Bool {
        guard let snapshot = self.withLock({ self.focusSnapshot }), snapshot.pid == pid else { return false }
        return self.isCapturedFieldFocused(snapshot)
    }

    /// Restores the captured live reference first, then falls back to remembered history. A live
    /// editable focus in the target app always wins and is never replaced.
    func restoreCapturedFocus(forPID pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if let focused = self.client.systemFocusedElement(), focused.pid == pid {
            if self.isSecureField(focused.element) { return false }
            if self.isEditableField(focused.element) {
                return true
            }
        }

        if let snapshot = self.withLock({ self.focusSnapshot }), snapshot.pid == pid {
            if let window = snapshot.window {
                _ = self.client.raiseAndFocusWindow(window, forPID: pid)
                self.postWindowRaiseDelay()
            }
            if self.isCapturedElementUsable(snapshot.element, expectedPID: pid),
               self.focusCapturedElement(
                   snapshot.element,
                   expectedFingerprint: snapshot.fingerprint,
                   expectedRuntimeIdentifier: snapshot.runtimeIdentifier,
                   expectedPID: pid
               )
            {
                return true
            }
        }

        if case .remembered = self.resolveTarget(forPID: pid) { return true }
        return false
    }

    private func focusCapturedElement(
        _ element: Client.Element,
        expectedFingerprint: TextFieldFingerprint?,
        expectedRuntimeIdentifier: String?,
        expectedPID: pid_t
    ) -> Bool {
        var didSetFocus = false
        for attempt in 0..<max(1, self.maxFocusAttempts) {
            if self.client.setFocused(element) {
                didSetFocus = true
            }
            if didSetFocus,
               self.isFocusedElementAfterSet(
                   element,
                   expectedFingerprint: expectedFingerprint,
                   expectedRuntimeIdentifier: expectedRuntimeIdentifier,
                   expectedPID: expectedPID
               )
            {
                return true
            }
            if attempt + 1 < self.maxFocusAttempts { self.interFocusAttemptDelay() }
        }
        return didSetFocus && self.isFocusedElementAfterSet(
            element,
            expectedFingerprint: expectedFingerprint,
            expectedRuntimeIdentifier: expectedRuntimeIdentifier,
            expectedPID: expectedPID
        )
    }

    // MARK: - Recording

    /// Records only a field that a successful insertion was dispatched to. History is keyed by
    /// app identity rather than PID, so it survives target-app and FluidVoice relaunches.
    func recordSuccessfulInsertion(element: Client.Element, pid: pid_t, window: Client.Element?) {
        guard self.isEnabled() else { return }
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return }
        guard self.client.applicationExists(pid) else { return }
        guard self.isEditableField(element), !self.isSecureField(element) else { return }
        guard let appIdentifier = self.client.applicationIdentifier(forPID: pid) else { return }

        let fingerprint = self.fingerprint(of: element, window: window)
        let runtimeIdentifier = self.client.runtimeIdentifier(of: element)
        let windowFingerprint = window.map(self.windowFingerprint)
        let timestamp = self.wallClockNow()

        self.lock.lock()
        self.touchAppLocked(appIdentifier)

        var fields = self.history[appIdentifier] ?? []
        if let index = fields.firstIndex(where: {
            $0.element.map { self.client.isSameElement($0, element) } ?? false
                || ($0.runtimeIdentifier != nil
                    && $0.runtimeIdentifier == runtimeIdentifier
                    && self.sameWindowIdentity(
                        recordedWindow: $0.window,
                        recordedFingerprint: $0.windowFingerprint,
                        newWindow: window,
                        newFingerprint: windowFingerprint
                    ))
                || (Self.sameFingerprintIdentity($0.fingerprint, fingerprint)
                    && self.sameWindowIdentity(
                        recordedWindow: $0.window,
                        recordedFingerprint: $0.windowFingerprint,
                        newWindow: window,
                        newFingerprint: windowFingerprint
                    ))
        }) {
            var existing = fields[index]
            existing.useCount += 1
            existing.lastUsedAt = timestamp
            existing.element = element
            existing.pid = pid
            existing.runtimeIdentifier = runtimeIdentifier
            existing.window = window
            existing.windowFingerprint = windowFingerprint
            existing.fingerprint = fingerprint
            fields[index] = existing
        } else {
            fields.append(TrackedTextField(
                element: element,
                pid: pid,
                runtimeIdentifier: runtimeIdentifier,
                window: window,
                windowFingerprint: windowFingerprint,
                fingerprint: fingerprint,
                lastUsedAt: timestamp,
                useCount: 1
            ))
        }

        fields.sort { self.sortPredicate($0, $1) }
        if fields.count > self.maxFieldsPerApp {
            fields = Array(fields.prefix(self.maxFieldsPerApp))
        }
        self.history[appIdentifier] = fields
        let persistedHistory = self.persistedHistoryAfterMutationLocked()
        self.lock.unlock()
        if let persistedHistory {
            self.persistence?.save(persistedHistory)
        }
    }

    // MARK: - Resolution

    /// Resolves one insertion target. `noHistory` lets the caller preserve its legacy first-use
    /// path. `refused` means history existed but could not be resolved safely (wrong window,
    /// ambiguity, budget exhaustion, secure focus); callers must abort before dispatch or any
    /// clipboard write. `.remembered` is only returned after the field
    /// is focused *and* semantically verified, so it is always safe to type into it.
    func resolveTarget(forPID pid: pid_t) -> Resolution {
        guard self.isEnabled() else { return .noHistory }
        guard self.client.frontmostApplicationPID() == pid else { return .refused }
        guard self.client.applicationExists(pid) else { return .refused }
        guard let appIdentifier = self.client.applicationIdentifier(forPID: pid) else { return .noHistory }
        let deadline = self.now() + self.budget.totalTimeLimit

        // Rule 1: a currently focused editable field always wins; never steal its focus.
        if let focused = self.client.systemFocusedElement(),
           focused.pid == pid
        {
            if self.isSecureField(focused.element) { return .refused }
            if self.isEditableField(focused.element) {
                return .current(focused.element, window: self.client.focusedWindow(forPID: pid))
            }
        }

        let currentWindow = self.client.focusedWindow(forPID: pid)
        let allCandidates = self.withLock { self.history[appIdentifier] ?? [] }
        guard allCandidates.isEmpty == false else { return .noHistory }
        let candidates = allCandidates.filter { self.matchesCurrentWindow($0, currentWindow: currentWindow) }
        guard candidates.isEmpty == false else { return .refused }
        self.client.setMessagingTimeout(forPID: pid, timeout: Float(self.budget.traversalTimeLimit))

        for candidate in candidates.prefix(self.budget.maxCandidates) {
            guard self.now() < deadline else {
                self.log("[TextFieldTargetResolver] total time budget exhausted")
                return .refused
            }

            let element: Client.Element
            if let liveElement = candidate.element, self.isLiveUsable(liveElement, expectedPID: pid) {
                element = liveElement
            } else {
                switch self.findByFingerprint(
                    candidate,
                    currentPID: pid,
                    currentWindow: currentWindow,
                    deadline: deadline
                ) {
                case let .match(matched):
                    element = matched
                case .notFound:
                    self.removeStaleCandidate(candidate, applicationIdentifier: appIdentifier)
                    continue
                case .indeterminate:
                    return .refused
                }
            }

            if self.focusAndVerify(element, expectedPID: pid, candidate: candidate, deadline: deadline) {
                self.refreshLiveReferences(
                    for: candidate,
                    applicationIdentifier: appIdentifier,
                    element: element,
                    pid: pid,
                    window: currentWindow
                )
                return .remembered(element, window: currentWindow)
            }
        }

        return .refused
    }

    // MARK: - Candidates

    private func matchesCurrentWindow(
        _ candidate: TrackedTextField<Client.Element>,
        currentWindow: Client.Element?
    ) -> Bool {
        guard let currentWindow else { return candidate.window == nil && candidate.windowFingerprint == nil }
        if let recordedWindow = candidate.window, self.client.isSameElement(recordedWindow, currentWindow) {
            return true
        }
        guard let recorded = candidate.windowFingerprint else { return false }
        return self.windowFingerprintsMatch(recorded, self.windowFingerprint(currentWindow))
    }

    /// Recency first, then frequency; fingerprint is a stable deterministic final key.
    private func sortPredicate(_ lhs: TrackedTextField<Client.Element>, _ rhs: TrackedTextField<Client.Element>) -> Bool {
        if lhs.lastUsedAt != rhs.lastUsedAt { return lhs.lastUsedAt > rhs.lastUsedAt }
        if lhs.useCount != rhs.useCount { return lhs.useCount > rhs.useCount }
        return Self.stableKey(lhs.fingerprint) < Self.stableKey(rhs.fingerprint)
    }

    private static func stableKey(_ fingerprint: TextFieldFingerprint) -> String {
        [
            fingerprint.identifier ?? "",
            fingerprint.role,
            fingerprint.parentPath.joined(separator: "/"),
            fingerprint.title ?? "",
        ].joined(separator: "|")
    }

    private static func sameFingerprintIdentity(
        _ lhs: TextFieldFingerprint,
        _ rhs: TextFieldFingerprint
    ) -> Bool {
        if let lhsIdentifier = lhs.identifier, let rhsIdentifier = rhs.identifier {
            return lhsIdentifier == rhsIdentifier && self.rolesEquivalent(lhs.role, rhs.role)
        }
        guard self.rolesEquivalent(lhs.role, rhs.role)
            && lhs.subrole == rhs.subrole
            && lhs.title == rhs.title
            && lhs.elementDescription == rhs.elementDescription
            && lhs.parentPath == rhs.parentPath
        else {
            return false
        }
        guard let lhsPosition = lhs.normalizedPosition, let rhsPosition = rhs.normalizedPosition else {
            // Without an OS identifier or a position, two visually identical fields cannot be
            // distinguished safely. Keep them separate instead of inventing an identity.
            return false
        }
        // Web/Electron fields move slightly as toolbars and composer chrome resize. Treat modest
        // drift as the same semantic field, while keeping nearby distinct fields separate.
        return self.positionDistance(lhsPosition, rhsPosition) <= 48
    }

    // MARK: - Live-reference validation

    private func isLiveUsable(_ element: Client.Element, expectedPID: pid_t) -> Bool {
        guard self.client.elementExists(element) else { return false }
        guard self.client.pid(of: element) == expectedPID else { return false }
        guard self.isEditableField(element), !self.isSecureField(element) else { return false }
        return true
    }

    private func isCapturedElementUsable(_ element: Client.Element, expectedPID: pid_t) -> Bool {
        guard self.client.elementExists(element), self.client.pid(of: element) == expectedPID else { return false }
        guard let role = self.client.role(of: element), Self.editableRoles.contains(role) else { return false }
        return !self.isSecureField(element)
    }

    // MARK: - Targeted tree walk

    /// Re-resolves a dead live reference by walking the app's AX tree looking for a fingerprint
    /// match. Strictly bounded by depth, visited nodes, and wall time. A complete scan with no
    /// match confirms a persisted entry is stale; ambiguous or incomplete scans stay
    /// indeterminate so transient AX failures never delete useful history.
    private func findByFingerprint(
        _ candidate: TrackedTextField<Client.Element>,
        currentPID: pid_t,
        currentWindow: Client.Element?,
        deadline: TimeInterval
    ) -> FingerprintLookup {
        let traversalDeadline = min(deadline, self.now() + self.budget.traversalTimeLimit)
        let root: Client.Element
        if let currentWindow {
            root = currentWindow
        } else if let window = candidate.window, self.client.elementExists(window) {
            root = window
        } else {
            root = self.client.applicationElement(forPID: currentPID)
        }

        var stack: [(element: Client.Element, depth: Int)] = [(root, 0)]
        var visited = 0
        var best: ScoredMatch?
        var ambiguous = false
        var exhaustedBudget = false

        while let (node, depth) = stack.popLast() {
            guard visited < self.budget.maxVisitedNodes else {
                self.log("[TextFieldTargetResolver] visited-node budget exhausted")
                exhaustedBudget = true
                break
            }
            guard self.now() < traversalDeadline else {
                self.log("[TextFieldTargetResolver] traversal time budget exhausted")
                exhaustedBudget = true
                break
            }
            visited += 1

            if self.isEditableField(node), !self.isSecureField(node) {
                let nodeFingerprint = self.fingerprint(of: node, window: currentWindow)
                if let score = self.matchScore(nodeFingerprint, against: candidate.fingerprint) {
                    let distance = Self.positionDistance(
                        nodeFingerprint.normalizedPosition,
                        candidate.fingerprint.normalizedPosition
                    )
                    if let currentBest = best {
                        if score > currentBest.score {
                            best = ScoredMatch(element: node, score: score, positionDistance: distance)
                            ambiguous = false
                        } else if score == currentBest.score, node !== currentBest.element {
                            // Position breaks ties, but a near-equal distance means we cannot tell the
                            // two fields apart: treat as ambiguous and abort rather than risk typing
                            // into the wrong field.
                            if distance + 8 < currentBest.positionDistance {
                                best = ScoredMatch(element: node, score: score, positionDistance: distance)
                                ambiguous = false
                            } else if currentBest.positionDistance + 8 < distance {
                                // existing best stays
                            } else {
                                ambiguous = true
                            }
                        }
                    } else {
                        best = ScoredMatch(element: node, score: score, positionDistance: distance)
                        ambiguous = false
                    }
                }
            }

            guard depth < self.budget.maxDepth else {
                let childProbe = self.client.children(of: node, maxCount: 1)
                if childProbe.wasTruncated || !childProbe.elements.isEmpty {
                    self.log("[TextFieldTargetResolver] depth budget exhausted")
                    exhaustedBudget = true
                    break
                }
                continue
            }
            let remainingNodeBudget = max(0, self.budget.maxVisitedNodes - visited - stack.count)
            let childBatch = self.client.children(of: node, maxCount: remainingNodeBudget)
            if childBatch.wasTruncated {
                self.log("[TextFieldTargetResolver] child budget exhausted")
                exhaustedBudget = true
                break
            }
            for child in childBatch.elements {
                stack.append((child, depth + 1))
            }
        }

        guard !exhaustedBudget else { return .indeterminate }
        guard ambiguous == false else {
            self.log("[TextFieldTargetResolver] ambiguous fingerprint match; refusing to choose")
            return .indeterminate
        }
        guard let best else { return .notFound }
        return .match(best.element)
    }

    // MARK: - Focus + verification

    private func focusAndVerify(
        _ element: Client.Element,
        expectedPID: pid_t,
        candidate: TrackedTextField<Client.Element>,
        deadline: TimeInterval
    ) -> Bool {
        var didSetFocus = false
        for attempt in 0..<max(1, self.maxFocusAttempts) {
            guard self.now() < deadline else { return false }
            if self.client.setFocused(element) {
                didSetFocus = true
            }
            if didSetFocus, self.verifyFocus(element, expectedPID: expectedPID, candidate: candidate) {
                return true
            }
            if attempt + 1 < self.maxFocusAttempts {
                self.interFocusAttemptDelay()
            }
        }
        return didSetFocus && self.verifyFocus(element, expectedPID: expectedPID, candidate: candidate)
    }

    /// Deliberately not strict identity: Chrome/Electron/Safari return a *different* AXUIElement
    /// for the same visual field after activation, so CFEqual fails there. We accept same-PID plus
    /// either identity, a fingerprint match, or a web focus-proxy role reached only after the
    /// actual remembered text field accepted `setFocused`.
    private func verifyFocus(
        _ element: Client.Element,
        expectedPID: pid_t,
        candidate: TrackedTextField<Client.Element>
    ) -> Bool {
        guard let focused = self.client.systemFocusedElement(), focused.pid == expectedPID else {
            return false
        }
        let focusedElement = focused.element
        guard !self.isSecureField(focusedElement) else { return false }
        if self.isEditableField(focusedElement) {
            if self.client.isSameElement(focusedElement, element) { return true }
            if let candidateRuntimeIdentifier = candidate.runtimeIdentifier,
               candidateRuntimeIdentifier == self.client.runtimeIdentifier(of: focusedElement)
            {
                return true
            }
            let focusedWindow = self.client.focusedWindow(forPID: expectedPID)
            return Self.sameFingerprintIdentity(
                self.fingerprint(of: focusedElement, window: focusedWindow),
                candidate.fingerprint
            )
        }
        if let role = self.client.role(of: focusedElement), Self.focusProxyRoles.contains(role) {
            return true
        }
        return false
    }

    // MARK: - Fingerprinting + matching

    func fingerprint(of element: Client.Element, window: Client.Element?) -> TextFieldFingerprint {
        var parentPath: [String] = []
        var ancestor = self.client.parent(of: element)
        var hops = 0
        while let current = ancestor, hops < 4 {
            var component = self.client.role(of: current) ?? "AXUnknown"
            if let identifier = self.client.identifier(of: current), identifier.isEmpty == false {
                component += "#" + identifier
            }
            parentPath.append(component)
            ancestor = self.client.parent(of: current)
            hops += 1
        }

        var normalizedPosition = self.client.position(of: element)
        if let position = normalizedPosition,
           let window,
           let windowOrigin = self.client.position(of: window)
        {
            normalizedPosition = CGPoint(x: position.x - windowOrigin.x, y: position.y - windowOrigin.y)
        }

        return TextFieldFingerprint(
            role: self.client.role(of: element) ?? "AXUnknown",
            subrole: self.client.subrole(of: element),
            identifier: self.client.identifier(of: element).flatMap { $0.isEmpty ? nil : $0 },
            title: self.client.title(of: element).flatMap { $0.isEmpty ? nil : $0 },
            elementDescription: self.client.elementDescription(of: element).flatMap { $0.isEmpty ? nil : $0 },
            parentPath: parentPath,
            normalizedPosition: normalizedPosition
        )
    }

    /// Returns a match score, or nil when the fingerprint cannot be the same field. Identifier
    /// and parent path dominate; position never participates here (tiebreaker only).
    func matchScore(_ fingerprint: TextFieldFingerprint, against candidate: TextFieldFingerprint) -> Int? {
        let candidateIdentifier = candidate.identifier
        if let identifier = fingerprint.identifier, let candidateIdentifier {
            // Both sides identify themselves: a different identifier means a different field.
            guard identifier == candidateIdentifier else { return nil }
            var score = 100
            score += 8 * Self.parentPathOverlap(fingerprint, candidate)
            return score
        }

        guard Self.rolesEquivalent(fingerprint.role, candidate.role) else { return nil }
        let overlap = Self.parentPathOverlap(fingerprint, candidate)
        var score = 20 + 8 * overlap
        var corroborated = overlap >= 2
        if let subrole = fingerprint.subrole, subrole == candidate.subrole {
            score += 10
        }
        if let title = fingerprint.title, title == candidate.title {
            score += 5
            corroborated = true
        }
        if let description = fingerprint.elementDescription, description == candidate.elementDescription {
            score += 5
            corroborated = true
        }
        // Role alone (e.g. "AXTextArea" anywhere in the tree) is never enough evidence.
        guard corroborated else { return nil }
        return score
    }

    static func rolesEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs
    }

    private static func parentPathOverlap(_ lhs: TextFieldFingerprint, _ rhs: TextFieldFingerprint) -> Int {
        var count = 0
        for (a, b) in zip(lhs.parentPath, rhs.parentPath) {
            guard a == b else { break }
            count += 1
        }
        return count
    }

    private static func positionDistance(_ lhs: CGPoint?, _ rhs: CGPoint?) -> CGFloat {
        guard let lhs, let rhs else { return .greatestFiniteMagnitude }
        return hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    // MARK: - Editable / secure

    func isEditableField(_ element: Client.Element) -> Bool {
        guard let role = self.client.role(of: element), Self.editableRoles.contains(role) else {
            return false
        }
        return self.client.isValueSettable(element)
    }

    func isSecureField(_ element: Client.Element) -> Bool {
        if self.client.isProtectedContent(element) { return true }
        if let role = self.client.role(of: element), role.lowercased().contains("secure") {
            return true
        }
        if let subrole = self.client.subrole(of: element), subrole.lowercased().contains("secure") {
            return true
        }
        return false
    }

    // MARK: - Store maintenance

    func clearHistory() {
        self.lock.lock()
        self.history.removeAll()
        self.appOrder.removeAll()
        self.historyChangedBeforeLoad = false
        if !self.persistenceLoaded {
            self.clearedBeforeLoad = true
        }
        self.lock.unlock()
        self.persistence?.clear()
    }

    func flushPersistence() {
        self.persistence?.flush()
    }

    private func finishLoadingPersistence(_ persistedHistory: PersistedTextFieldTargetHistory?) {
        self.lock.lock()
        let suppressPersistedMerge = self.clearedBeforeLoad
        let shouldDiscard = !self.isEnabled()
        if shouldDiscard {
            self.history.removeAll()
            self.appOrder.removeAll()
        } else if !suppressPersistedMerge, let persistedHistory {
            self.mergePersistedHistoryLocked(persistedHistory)
        }
        self.persistenceLoaded = true
        self.normalizeHistoryBoundsLocked()
        let shouldSave = !shouldDiscard && (
            (!suppressPersistedMerge && persistedHistory != nil) || self.historyChangedBeforeLoad
        )
        let normalizedHistory = shouldSave ? self.makePersistedHistoryLocked() : nil
        self.historyChangedBeforeLoad = false
        self.clearedBeforeLoad = false
        self.lock.unlock()

        if shouldDiscard {
            self.persistence?.clear()
        } else if suppressPersistedMerge, normalizedHistory == nil {
            self.persistence?.clear()
        } else if let normalizedHistory {
            self.persistence?.save(normalizedHistory)
        }
    }

    private func mergePersistedHistoryLocked(_ persistedHistory: PersistedTextFieldTargetHistory) {
        guard persistedHistory.schemaVersion == PersistedTextFieldTargetHistory.currentSchemaVersion else { return }

        for app in persistedHistory.apps where !app.applicationIdentifier.isEmpty {
            var normalizedPersisted: [TrackedTextField<Client.Element>] = []
            for persisted in app.fields where self.isValidPersistedField(persisted) {
                let loaded = TrackedTextField<Client.Element>(
                    element: nil,
                    pid: nil,
                    runtimeIdentifier: nil,
                    window: nil,
                    windowFingerprint: persisted.windowFingerprint,
                    fingerprint: persisted.fingerprint,
                    lastUsedAt: persisted.lastUsedAt,
                    useCount: persisted.useCount
                )
                if let duplicateIndex = normalizedPersisted.firstIndex(where: {
                    self.sameTrackedIdentity($0, loaded)
                }) {
                    normalizedPersisted[duplicateIndex].lastUsedAt = max(
                        normalizedPersisted[duplicateIndex].lastUsedAt,
                        loaded.lastUsedAt
                    )
                    normalizedPersisted[duplicateIndex].useCount = max(
                        normalizedPersisted[duplicateIndex].useCount,
                        loaded.useCount
                    )
                } else {
                    normalizedPersisted.append(loaded)
                }
            }

            var fields = self.history[app.applicationIdentifier] ?? []
            for loaded in normalizedPersisted {
                if let existingIndex = fields.firstIndex(where: { self.sameTrackedIdentity($0, loaded) }) {
                    // Any entries captured before the asynchronous load are from this new session,
                    // so their counts are additional to the persisted lifetime count.
                    fields[existingIndex].useCount += loaded.useCount
                    fields[existingIndex].lastUsedAt = max(fields[existingIndex].lastUsedAt, loaded.lastUsedAt)
                } else {
                    fields.append(loaded)
                }
            }
            self.history[app.applicationIdentifier] = fields
        }
    }

    private func isValidPersistedField(_ field: PersistedTextFieldTarget) -> Bool {
        guard field.useCount > 0, field.lastUsedAt.isFinite else { return false }
        guard Self.editableRoles.contains(field.fingerprint.role) else { return false }
        let role = field.fingerprint.role.lowercased()
        let subrole = field.fingerprint.subrole?.lowercased() ?? ""
        return !role.contains("secure") && !subrole.contains("secure")
    }

    private func normalizeHistoryBoundsLocked() {
        for appIdentifier in self.history.keys {
            var fields = self.history[appIdentifier] ?? []
            fields.sort { self.sortPredicate($0, $1) }
            self.history[appIdentifier] = Array(fields.prefix(self.maxFieldsPerApp))
        }

        self.appOrder = self.history.keys.sorted {
            let lhs = self.history[$0]?.first?.lastUsedAt ?? -.greatestFiniteMagnitude
            let rhs = self.history[$1]?.first?.lastUsedAt ?? -.greatestFiniteMagnitude
            if lhs != rhs { return lhs > rhs }
            return $0 < $1
        }
        while self.appOrder.count > self.maxTrackedApps, let evicted = self.appOrder.last {
            self.appOrder.removeLast()
            self.history.removeValue(forKey: evicted)
        }
    }

    private func persistedHistoryAfterMutationLocked() -> PersistedTextFieldTargetHistory? {
        guard self.persistenceLoaded else {
            self.historyChangedBeforeLoad = true
            return nil
        }
        return self.makePersistedHistoryLocked()
    }

    private func makePersistedHistoryLocked() -> PersistedTextFieldTargetHistory {
        let apps = self.appOrder.compactMap { appIdentifier -> PersistedTextFieldTargetApp? in
            guard let fields = self.history[appIdentifier], !fields.isEmpty else { return nil }
            return PersistedTextFieldTargetApp(
                applicationIdentifier: appIdentifier,
                fields: fields.map {
                    PersistedTextFieldTarget(
                        windowFingerprint: $0.windowFingerprint,
                        fingerprint: $0.fingerprint,
                        lastUsedAt: $0.lastUsedAt,
                        useCount: $0.useCount
                    )
                }
            )
        }
        return PersistedTextFieldTargetHistory(apps: apps)
    }

    private func removeStaleCandidate(
        _ candidate: TrackedTextField<Client.Element>,
        applicationIdentifier: String
    ) {
        self.lock.lock()
        guard var fields = self.history[applicationIdentifier],
              let index = fields.firstIndex(where: { self.sameTrackedIdentity($0, candidate) })
        else {
            self.lock.unlock()
            return
        }
        fields.remove(at: index)
        if fields.isEmpty {
            self.history.removeValue(forKey: applicationIdentifier)
            self.appOrder.removeAll { $0 == applicationIdentifier }
        } else {
            self.history[applicationIdentifier] = fields
        }
        let persistedHistory = self.persistedHistoryAfterMutationLocked()
        self.lock.unlock()
        if let persistedHistory {
            self.persistence?.save(persistedHistory)
        }
    }

    private func refreshLiveReferences(
        for candidate: TrackedTextField<Client.Element>,
        applicationIdentifier: String,
        element: Client.Element,
        pid: pid_t,
        window: Client.Element?
    ) {
        self.lock.lock()
        if var fields = self.history[applicationIdentifier],
           let index = fields.firstIndex(where: { self.sameTrackedIdentity($0, candidate) })
        {
            fields[index].element = element
            fields[index].pid = pid
            fields[index].runtimeIdentifier = self.client.runtimeIdentifier(of: element)
            fields[index].window = window
            self.history[applicationIdentifier] = fields
        }
        self.lock.unlock()
    }

    private func sameTrackedIdentity(
        _ lhs: TrackedTextField<Client.Element>,
        _ rhs: TrackedTextField<Client.Element>
    ) -> Bool {
        guard Self.sameFingerprintIdentity(lhs.fingerprint, rhs.fingerprint) else { return false }
        switch (lhs.windowFingerprint, rhs.windowFingerprint) {
        case (nil, nil):
            return true
        case let (lhsWindow?, rhsWindow?):
            return self.windowFingerprintsMatch(lhsWindow, rhsWindow)
        default:
            return false
        }
    }

    private func touchAppLocked(_ appIdentifier: String) {
        self.appOrder.removeAll { $0 == appIdentifier }
        self.appOrder.insert(appIdentifier, at: 0)
        while self.appOrder.count > self.maxTrackedApps, let evicted = self.appOrder.last {
            self.appOrder.removeLast()
            self.history.removeValue(forKey: evicted)
        }
    }

    private func windowFingerprint(_ window: Client.Element) -> TextFieldWindowFingerprint {
        TextFieldWindowFingerprint(
            identifier: self.client.identifier(of: window).flatMap { $0.isEmpty ? nil : $0 },
            title: self.client.title(of: window).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private func sameWindowIdentity(
        recordedWindow: Client.Element?,
        recordedFingerprint: TextFieldWindowFingerprint?,
        newWindow: Client.Element?,
        newFingerprint: TextFieldWindowFingerprint?
    ) -> Bool {
        if let recordedWindow, let newWindow, self.client.isSameElement(recordedWindow, newWindow) {
            return true
        }
        if let recordedFingerprint, let newFingerprint {
            return self.windowFingerprintsMatch(recordedFingerprint, newFingerprint)
        }
        return recordedWindow == nil && recordedFingerprint == nil
            && newWindow == nil && newFingerprint == nil
    }

    private func windowFingerprintsMatch(
        _ lhs: TextFieldWindowFingerprint,
        _ rhs: TextFieldWindowFingerprint
    ) -> Bool {
        if let lhsIdentifier = lhs.identifier, let rhsIdentifier = rhs.identifier {
            guard lhsIdentifier == rhsIdentifier else { return false }
            if let lhsTitle = lhs.title, let rhsTitle = rhs.title {
                return lhsTitle == rhsTitle
            }
            return true
        }
        if lhs.identifier != nil || rhs.identifier != nil { return false }
        guard let lhsTitle = lhs.title, let rhsTitle = rhs.title else { return false }
        return lhsTitle == rhsTitle
    }

    private func isCapturedFieldFocused(_ snapshot: FocusSnapshot) -> Bool {
        guard let expectedFingerprint = snapshot.fingerprint,
              let focused = self.client.systemFocusedElement(),
              focused.pid == snapshot.pid,
              self.isEditableField(focused.element),
              !self.isSecureField(focused.element)
        else {
            return false
        }
        if self.client.isSameElement(focused.element, snapshot.element) { return true }
        if let runtimeIdentifier = snapshot.runtimeIdentifier,
           runtimeIdentifier == self.client.runtimeIdentifier(of: focused.element)
        {
            return true
        }
        let currentWindow = self.client.focusedWindow(forPID: snapshot.pid)
        let focusedFingerprint = self.fingerprint(of: focused.element, window: currentWindow)
        return Self.sameFingerprintIdentity(focusedFingerprint, expectedFingerprint)
    }

    /// A broad web proxy is acceptable only after the exact captured element accepted a focus
    /// request. It is never evidence that the field was already focused before that request.
    private func isFocusedElementAfterSet(
        _ expectedElement: Client.Element,
        expectedFingerprint: TextFieldFingerprint?,
        expectedRuntimeIdentifier: String?,
        expectedPID: pid_t
    ) -> Bool {
        guard let focused = self.client.systemFocusedElement(), focused.pid == expectedPID else { return false }
        if self.client.isSameElement(focused.element, expectedElement) { return true }
        if let expectedRuntimeIdentifier,
           expectedRuntimeIdentifier == self.client.runtimeIdentifier(of: focused.element)
        {
            return true
        }
        if let expectedFingerprint,
           self.isEditableField(focused.element),
           !self.isSecureField(focused.element)
        {
            let currentWindow = self.client.focusedWindow(forPID: expectedPID)
            let focusedFingerprint = self.fingerprint(of: focused.element, window: currentWindow)
            return Self.sameFingerprintIdentity(focusedFingerprint, expectedFingerprint)
        }
        guard let role = self.client.role(of: focused.element) else { return false }
        return Self.focusProxyRoles.contains(role)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return body()
    }

    /// Test/introspection support.
    func trackedFields(forPID pid: pid_t) -> [TrackedTextField<Client.Element>] {
        guard let appIdentifier = self.client.applicationIdentifier(forPID: pid) else { return [] }
        return self.withLock { self.history[appIdentifier] ?? [] }
    }
}

// MARK: - System client

struct SystemTextFieldAccessibilityClient: TextFieldAccessibilityClient {
    typealias Element = AXUIElement

    func applicationElement(forPID pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    func systemFocusedElement() -> (element: AXUIElement, pid: pid_t)? {
        let systemWide = AXUIElementCreateSystemWide()
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref,
              CFGetTypeID(ref) == AXUIElementGetTypeID()
        else {
            return nil
        }
        let element = unsafeBitCast(ref, to: AXUIElement.self)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return (element, pid)
    }

    func focusedWindow(forPID pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        return Self.copyElement(from: app, attribute: kAXFocusedWindowAttribute as CFString)
            ?? Self.copyElement(from: app, attribute: kAXMainWindowAttribute as CFString)
    }

    func frontmostApplicationPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func applicationExists(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid) != nil
    }

    func applicationIdentifier(forPID pid: pid_t) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        if let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty {
            return "bundle:\(bundleIdentifier)"
        }
        if let bundleURL = app.bundleURL {
            return "url:\(bundleURL.path)"
        }
        return nil
    }

    func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    func role(of element: AXUIElement) -> String? {
        Self.copyString(from: element, attribute: kAXRoleAttribute as CFString)
    }

    func subrole(of element: AXUIElement) -> String? {
        Self.copyString(from: element, attribute: kAXSubroleAttribute as CFString)
    }

    func identifier(of element: AXUIElement) -> String? {
        if let identifier = Self.copyString(from: element, attribute: "AXIdentifier" as CFString),
           !identifier.isEmpty
        {
            return identifier
        }
        guard let domIdentifier = Self.copyString(from: element, attribute: "AXDOMIdentifier" as CFString),
              !domIdentifier.isEmpty
        else {
            return nil
        }
        return "dom:\(domIdentifier)"
    }

    func runtimeIdentifier(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "ChromeAXNodeId" as CFString, &value) == .success,
              let value
        else {
            return nil
        }
        if let number = value as? NSNumber {
            return "chrome:\(number.stringValue)"
        }
        if let string = value as? String, !string.isEmpty {
            return "chrome:\(string)"
        }
        return nil
    }

    func title(of element: AXUIElement) -> String? {
        Self.copyString(from: element, attribute: kAXTitleAttribute as CFString)
    }

    func elementDescription(of element: AXUIElement) -> String? {
        Self.copyString(from: element, attribute: kAXDescriptionAttribute as CFString)
    }

    func position(of element: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &ref) == .success,
              let ref,
              CFGetTypeID(ref) == AXValueGetTypeID()
        else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(unsafeBitCast(ref, to: AXValue.self), .cgPoint, &point) else { return nil }
        return point
    }

    func parent(of element: AXUIElement) -> AXUIElement? {
        Self.copyElement(from: element, attribute: kAXParentAttribute as CFString)
    }

    func children(of element: AXUIElement, maxCount: Int) -> (elements: [AXUIElement], wasTruncated: Bool) {
        var totalCount = 0
        let countResult = AXUIElementGetAttributeValueCount(
            element,
            kAXChildrenAttribute as CFString,
            &totalCount
        )
        guard countResult == .success else {
            let ordinaryLeaf = countResult == .noValue || countResult == .attributeUnsupported
            return ([], !ordinaryLeaf)
        }
        guard totalCount > 0 else { return ([], false) }
        guard maxCount > 0 else { return ([], true) }

        let requestedCount = min(totalCount, maxCount)
        var ref: CFArray?
        guard AXUIElementCopyAttributeValues(
            element,
            kAXChildrenAttribute as CFString,
            0,
            requestedCount,
            &ref
        ) == .success,
            let children = ref as? [AXUIElement]
        else {
            return ([], true)
        }
        return (children, totalCount > requestedCount)
    }

    func isSameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }

    func isValueSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    func isProtectedContent(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            NSAccessibility.Attribute.containsProtectedContent.rawValue as CFString,
            &ref
        ) == .success,
            let number = ref as? NSNumber
        else {
            return false
        }
        return number.boolValue
    }

    func elementExists(_ element: AXUIElement) -> Bool {
        self.pid(of: element) != nil && self.role(of: element) != nil
    }

    @discardableResult
    func setFocused(_ element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    @discardableResult
    func raiseAndFocusWindow(_ window: AXUIElement, forPID pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
        let main = AXUIElementSetAttributeValue(app, kAXMainWindowAttribute as CFString, window) == .success
        let focused = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window) == .success
        return raised || main || focused
    }

    func setMessagingTimeout(forPID pid: pid_t, timeout: Float) {
        _ = AXUIElementSetMessagingTimeout(AXUIElementCreateApplication(pid), timeout)
    }

    static func copyElement(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
              let ref,
              CFGetTypeID(ref) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeBitCast(ref, to: AXUIElement.self)
    }

    static func copyString(from element: AXUIElement, attribute: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return ref as? String
    }
}

// MARK: - Shared instance

typealias SystemTextFieldTargetResolver = TextFieldTargetResolver<SystemTextFieldAccessibilityClient>

extension TextFieldTargetResolver where Client == SystemTextFieldAccessibilityClient {
    static let shared = SystemTextFieldTargetResolver(
        client: SystemTextFieldAccessibilityClient(),
        persistence: FileTextFieldHistoryStore(),
        isEnabled: { SettingsStore.shared.rememberTextFieldsEnabled }
    )
}
