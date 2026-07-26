import AppKit
import SwiftUI

/// A drop target that accepts both concrete file URLs and file-promise drags
/// (e.g. from Voice Memos), and resolves promised files into per-item staging
/// directories before reporting them via callbacks.
///
/// The pure strategy/staging/filtering logic lives in `PromiseDropSupport`;
/// this view only owns AppKit drag plumbing and the async resolution poll.
struct PromiseAwareDropView: NSViewRepresentable {
    let onTargetedChange: (Bool) -> Void
    let onFiles: ([(url: URL, stagingDir: URL?)]) -> Void
    let onError: (String) -> Void

    func makeNSView(context: Context) -> DropTargetView {
        let view = DropTargetView()
        view.onTargetedChange = self.onTargetedChange
        view.onFiles = self.onFiles
        view.onError = self.onError
        return view
    }

    func updateNSView(_ nsView: DropTargetView, context: Context) {
        nsView.onTargetedChange = self.onTargetedChange
        nsView.onFiles = self.onFiles
        nsView.onError = self.onError
    }

    // MARK: - Drop target

    final class DropTargetView: NSView {
        var onTargetedChange: (Bool) -> Void = { _ in }
        var onFiles: ([(url: URL, stagingDir: URL?)]) -> Void = { _ in }
        var onError: (String) -> Void = { _ in }

        /// Shared background queue for `NSFilePromiseReceiver` resolution. Static
        /// so in-flight promise resolution survives the view being destroyed
        /// (e.g. by sidebar navigation) mid-drop.
        private static let promiseQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 4
            return queue
        }()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            self.configureDropTypes()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            self.configureDropTypes()
        }

        private func configureDropTypes() {
            let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType(rawValue: $0) }
            self.registerForDraggedTypes([.fileURL] + promiseTypes)
        }

        /// The view sits in an `.overlay` so AppKit's front-to-back drag-target
        /// search finds it above the SwiftUI content; returning nil here lets
        /// every normal mouse event fall through to the UI beneath. Drag
        /// dispatch does not consult `hitTest`, so drops still arrive.
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DebugLogger.shared.debug(
                "Drop target attached [inWindow=\(self.window != nil), frame=\(self.frame)]",
                source: "PromiseAwareDropView"
            )
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            let types = (sender.draggingPasteboard.types ?? []).map(\.rawValue)
            let strategy = PromiseDropSupport.strategy(forPasteboardTypes: types)
            DebugLogger.shared.debug(
                "Drag entered [strategy=\(String(describing: strategy)), frame=\(self.frame)]",
                source: "PromiseAwareDropView"
            )
            guard strategy != nil else {
                return []
            }
            self.onTargetedChange(true)
            return .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            self.onTargetedChange(false)
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            self.onTargetedChange(false)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let pasteboard = sender.draggingPasteboard
            let types = (pasteboard.types ?? []).map(\.rawValue)
            DebugLogger.shared.debug(
                "Perform drag [types=\(types.count)]",
                source: "PromiseAwareDropView"
            )
            guard let strategy = PromiseDropSupport.strategy(forPasteboardTypes: types) else {
                self.onError(MeetingTranscriptionService.dropErrorCopy)
                return false
            }

            switch strategy {
            case .concreteFileURLs:
                return self.handleConcreteURLs(pasteboard: pasteboard)
            case .filePromise:
                return self.handleFilePromises(sender: sender, pasteboard: pasteboard)
            }
        }

        // MARK: - Concrete File URLs

        private func handleConcreteURLs(pasteboard: NSPasteboard) -> Bool {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
                  !urls.isEmpty else {
                self.onError(MeetingTranscriptionService.dropErrorCopy)
                return false
            }

            let supported = PromiseDropSupport.filterSupported(urls)
            if supported.isEmpty {
                self.onError(MeetingTranscriptionService.dropErrorCopy)
                return false
            }

            self.onFiles(supported.map { (url: $0, stagingDir: nil) })
            return true
        }

        // MARK: - File Promises

        private func handleFilePromises(sender: NSDraggingInfo, pasteboard: NSPasteboard) -> Bool {
            let session: PromiseDropSupport.StagingSession
            do {
                session = try PromiseDropSupport.StagingSession()
            } catch {
                self.onError("Could not prepare a staging directory for the drop: \(error.localizedDescription)")
                return false
            }
            let legacyDir = try? session.makeItemDirectory()
            let dataDir = try? session.makeItemDirectory()
            // Captured by value so resolution keeps working (and can still hand
            // files to the app-level batch session) if this view is destroyed
            // by navigation while the drop is resolving.
            let onFiles = self.onFiles
            let onError = self.onError

            // Every pasteboard read can block indefinitely (verified: the same
            // read is instant on one drop and deadlocks on the next), and a
            // block inside performDragOperation freezes the system-wide drag
            // session. So performDragOperation returns immediately and ALL
            // pasteboard interaction happens on throwaway background threads;
            // the main thread only ever polls the staging directories.
            //
            // NOTE: using `sender`/`pasteboard` after performDragOperation has
            // returned, from another thread, is outside AppKit's documented
            // lifetime contract. It is the only arrangement that neither
            // deadlocks nor loses the drop (verified live against Voice Memos);
            // if a provider stops answering, the reads fail harmlessly on their
            // background threads and the poll timeout reports the failure.
            let state = ResolutionState()
            state.beginInFlight() // outer worker token, released when it finishes

            // The poller starts before any pasteboard read, so even a worker
            // thread that hangs on its first read cannot leave the drop without
            // a timeout/error path. Deliberately not tied to the view lifetime.
            Task { @MainActor in
                await DropTargetView.resolvePromises(
                    session: session,
                    state: state,
                    legacyDir: legacyDir,
                    dataDir: dataDir,
                    onFiles: onFiles,
                    onError: onError
                )
            }

            Self.detachWorker {
                defer { state.endInFlight() }

                // Modern path: each NSFilePromiseReceiver writes into its own
                // item directory via the shared background operation queue. A
                // directory counts as delivered only after its completion
                // callback fires — polling alone could hand over a file whose
                // (e.g. iCloud) download stalled mid-write.
                if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] {
                    for receiver in receivers {
                        guard let dir = try? session.makeItemDirectory() else { continue }
                        state.registerReceiverDir(dir)
                        receiver.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: Self.promiseQueue) { url, error in
                            if let error {
                                DebugLogger.shared.debug(
                                    "Modern promise receiver failed [\(url.lastPathComponent)]: \(error.localizedDescription)",
                                    source: "PromiseAwareDropView"
                                )
                            } else {
                                state.markCompleted(dir)
                            }
                        }
                    }
                }

                let suggestedName = pasteboard.string(
                    forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-suggested-file-name")
                )
                let promisedTypeID = pasteboard.string(
                    forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")
                )
                DebugLogger.shared.debug(
                    "Promise drop [receivers=\(state.receiverDirsSnapshot().count), type=\(promisedTypeID ?? "?"), name=\(suggestedName ?? "?")]",
                    source: "PromiseAwareDropView"
                )

                // Raw-data fallback: some providers (verified for Voice Memos)
                // also put the complete file bytes on the pasteboard under the
                // promised content type. Memory-heavy for long recordings, so
                // it is the last resort in the delivery priority order.
                if let dataDir, let typeID = promisedTypeID {
                    let fileName = suggestedName ?? "Dropped Audio"
                    guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(typeID)),
                          !data.isEmpty else { return }
                    let target = dataDir.appendingPathComponent(fileName)
                    do {
                        try data.write(to: target)
                        DebugLogger.shared.debug(
                            "Raw-data fallback wrote \(data.count) bytes to \(target.lastPathComponent)",
                            source: "PromiseAwareDropView"
                        )
                    } catch {
                        DebugLogger.shared.debug(
                            "Raw-data fallback write failed: \(error.localizedDescription)",
                            source: "PromiseAwareDropView"
                        )
                    }
                }

                // Legacy fallback (deprecated namesOfPromisedFilesDroppedAtDestination:),
                // strictly last resort. A pending legacy request freezes the
                // source app's promise machinery until it answers (verified
                // live: Voice Memos unresponsive for 35-80s, blocking further
                // drags), so it only fires if neither the modern receiver nor
                // the raw-data path has produced anything within a short
                // window. Invoked via perform(_:) with a string selector so no
                // deprecation warning is emitted.
                if let legacyDir {
                    let waitDeadline = Date().addingTimeInterval(3)
                    var otherPathDelivered = false
                    while Date() < waitDeadline {
                        let dataLanded = dataDir.map {
                            !((try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? []).isEmpty
                        } ?? false
                        if dataLanded || !state.completedSnapshot().isEmpty {
                            otherPathDelivered = true
                            break
                        }
                        Thread.sleep(forTimeInterval: 0.2)
                    }
                    if !otherPathDelivered {
                        state.beginInFlight()
                        Self.detachWorker {
                            defer { state.endInFlight() }
                            let selector = Selector(("namesOfPromisedFilesDroppedAtDestination:"))
                            let names = (sender.perform(selector, with: legacyDir)?
                                .takeUnretainedValue() as? [String]) ?? []
                            DebugLogger.shared.debug(
                                "Legacy promise names: \(names)",
                                source: "PromiseAwareDropView"
                            )
                        }
                    }
                }
            }
            return true
        }

        /// Thread-safe resolution state shared between the background delivery
        /// threads and the main-actor poller: which receiver dirs have completed,
        /// and whether the legacy/raw-data reads are still in flight (under heavy
        /// inference load a provider can take 60s+ to answer — verified live —
        /// and the poller must not give up and sweep the staging dirs while an
        /// answer is still coming).
        private final class ResolutionState: @unchecked Sendable {
            private let lock = NSLock()
            private var receiverDirs: [URL] = []
            private var completed: Set<URL> = []
            private var inFlightCount = 0

            func registerReceiverDir(_ dir: URL) {
                self.lock.lock()
                defer { self.lock.unlock() }
                self.receiverDirs.append(dir)
            }

            func receiverDirsSnapshot() -> [URL] {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.receiverDirs
            }

            func markCompleted(_ dir: URL) {
                self.lock.lock()
                defer { self.lock.unlock() }
                self.completed.insert(dir)
            }

            func completedSnapshot() -> Set<URL> {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.completed
            }

            func beginInFlight() {
                self.lock.lock()
                defer { self.lock.unlock() }
                self.inFlightCount += 1
            }

            func endInFlight() {
                self.lock.lock()
                defer { self.lock.unlock() }
                self.inFlightCount -= 1
            }

            var hasInFlightWork: Bool {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.inFlightCount > 0
            }
        }

        /// Detached worker at user-initiated QoS: default-QoS threads get starved
        /// while ML inference saturates the cores, which is exactly when a second
        /// drop arrives mid-batch.
        private static func detachWorker(_ body: @escaping () -> Void) {
            let thread = Thread(block: body)
            thread.qualityOfService = .userInitiated
            thread.start()
        }

        // MARK: - Promise Resolution Poll

        private static func resolvePromises(
            session: PromiseDropSupport.StagingSession,
            state: ResolutionState,
            legacyDir: URL?,
            dataDir: URL?,
            onFiles: @escaping ([(url: URL, stagingDir: URL?)]) -> Void,
            onError: @escaping (String) -> Void
        ) async {
            let pollInterval: UInt64 = 200_000_000
            let softTimeout: TimeInterval = 30
            // Under heavy inference load a provider can take 60s+ to answer
            // (verified live: 80s for a second drop mid-batch). While any
            // delivery thread is still in flight the poll keeps waiting, up to
            // a hard cap so a truly wedged provider still ends in an error.
            let hardTimeout: TimeInterval = 120
            let modernGrace: TimeInterval = 1.5
            let start = Date()

            func makeContext() -> DeliveryContext {
                let receiverDirs = state.receiverDirsSnapshot()
                let completed = state.completedSnapshot()
                return DeliveryContext(
                    allDirs: receiverDirs + [legacyDir, dataDir].compactMap(\.self),
                    pendingReceiverDirs: receiverDirs.filter { !completed.contains($0) },
                    totalExpected: max(receiverDirs.count, 1),
                    session: session,
                    onFiles: onFiles,
                    onError: onError
                )
            }

            var fallbackPrevSizes: [URL: Int64] = [:]

            while true {
                let elapsed = Date().timeIntervalSince(start)
                if elapsed >= hardTimeout { break }
                if elapsed >= softTimeout, !state.hasInFlightWork { break }

                // A receiver dir only counts once its completion callback fired —
                // a stalled (e.g. iCloud) download must never be delivered as a
                // truncated file just because its size held still between polls.
                let receiverDirs = state.receiverDirsSnapshot()
                let readyModernDirs = state.completedSnapshot()
                let modernFiles = self.listFiles(in: receiverDirs.filter(readyModernDirs.contains))
                let legacyFiles = self.listFiles(in: [legacyDir].compactMap(\.self))
                let dataFiles = self.listFiles(in: [dataDir].compactMap(\.self))
                let fallbackSizes = self.sizeMap(for: legacyFiles + dataFiles)

                // Modern succeeded outright: every registered receiver completed.
                // (Receivers register in one tight loop with no pasteboard call
                // in between, so a partially-registered snapshot is a micro-race
                // at worst; completion still requires each dir's callback.)
                let modernComplete = !receiverDirs.isEmpty
                    && readyModernDirs.count >= receiverDirs.count
                    && !modernFiles.isEmpty
                if modernComplete {
                    self.deliver(modern: modernFiles, legacy: legacyFiles, data: dataFiles, context: makeContext())
                    return
                }

                // Modern produced nothing past the grace period but a fallback
                // landed and its sizes are stable — use the fallback copies.
                let modernProducedNothing = readyModernDirs.isEmpty && elapsed > modernGrace
                let fallbackStable = !fallbackSizes.isEmpty && fallbackSizes == fallbackPrevSizes
                if modernProducedNothing && fallbackStable {
                    self.deliver(modern: [], legacy: legacyFiles, data: dataFiles, context: makeContext())
                    return
                }

                fallbackPrevSizes = fallbackSizes
                try? await Task.sleep(nanoseconds: pollInterval)
            }

            // Timeout: deliver whatever completed, preferring modern. Incomplete
            // receiver dirs are excluded (possible truncation) and surface via
            // the partial-failure error below.
            let receiverDirs = state.receiverDirsSnapshot()
            let readyModernDirs = state.completedSnapshot()
            self.deliver(
                modern: self.listFiles(in: receiverDirs.filter(readyModernDirs.contains)),
                legacy: self.listFiles(in: [legacyDir].compactMap(\.self)),
                data: self.listFiles(in: [dataDir].compactMap(\.self)),
                context: makeContext()
            )
        }

        /// Everything `deliver` needs besides the per-path file lists.
        private struct DeliveryContext {
            let allDirs: [URL]
            /// Receiver dirs whose promise hasn't completed yet. They must NOT
            /// be swept at delivery: the source app may still be writing into
            /// them, and deleting the destination leaves its promise session
            /// unresolved — Voice Memos then refuses to start any further drag
            /// until restarted (verified live). They're cleaned up after the
            /// promise completes (or a 120s deadline) by a deferred task.
            let pendingReceiverDirs: [URL]
            let totalExpected: Int
            let session: PromiseDropSupport.StagingSession
            let onFiles: ([(url: URL, stagingDir: URL?)]) -> Void
            let onError: (String) -> Void
        }

        /// Delivers the resolved files. Selection/dedup rules live in
        /// `PromiseDropSupport.selectDelivery`; unsupported formats are filtered
        /// like the concrete-URL path.
        private static func deliver(
            modern: [URL],
            legacy: [URL],
            data: [URL],
            context: DeliveryContext
        ) {
            DebugLogger.shared.debug(
                "Promise delivery [modern=\(modern.count), legacy=\(legacy.count), data=\(data.count), expected=\(context.totalExpected)]",
                source: "PromiseAwareDropView"
            )
            let selected = PromiseDropSupport.selectDelivery(modern: modern, legacy: legacy, data: data)
            let supported = PromiseDropSupport.filterSupported(selected)
            let result = supported.map { (url: $0, stagingDir: $0.deletingLastPathComponent()) }

            if result.isEmpty {
                context.session.removeAll()
                let reason = selected.isEmpty
                    ? "No files could be read from the drop."
                    : "The dropped files are not a supported format."
                context.onError("\(reason) \(MeetingTranscriptionService.dropErrorCopy)")
                return
            }

            // Item dirs that hold no delivered file — losing duplicates (e.g. the
            // raw-data copy when the modern receiver won) and empty shells from
            // failed paths — are dead weight. Deleting them can race the still-
            // running legacy/data writer threads; that is harmless (the losers'
            // files are throwaway copies) and keeps the temp dir clean. The
            // batch coordinator removes the delivered dirs (and then the empty
            // session root) after each item's transcription.
            let pendingPaths = Set(context.pendingReceiverDirs.map(\.standardizedFileURL.path))
            for dir in PromiseDropSupport.sweepableDirs(allDirs: context.allDirs, deliveredFiles: supported)
            where !pendingPaths.contains(dir.standardizedFileURL.path) {
                try? FileManager.default.removeItem(at: dir)
            }

            context.onFiles(result)
            if result.count < context.totalExpected {
                context.onError("\(context.totalExpected - result.count) file(s) could not be read from the drop.")
            }

            self.cleanUpLater(pendingDirs: context.pendingReceiverDirs)
        }

        /// Removes still-pending receiver dirs once their promise has had time
        /// to finish writing (their content is a duplicate of what was already
        /// delivered), then prunes the session root if it ended up empty.
        private static func cleanUpLater(pendingDirs: [URL]) {
            guard !pendingDirs.isEmpty else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                for dir in pendingDirs {
                    try? FileManager.default.removeItem(at: dir)
                }
                for parent in Set(pendingDirs.map { $0.deletingLastPathComponent() })
                where parent.lastPathComponent.hasPrefix(PromiseDropSupport.stagingRootPrefix) {
                    if ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []).isEmpty {
                        try? FileManager.default.removeItem(at: parent)
                    }
                }
            }
        }

        // MARK: - Filesystem Helpers

        private static func listFiles(in dirs: [URL]) -> [URL] {
            var files: [URL] = []
            for dir in dirs {
                guard let entries = try? FileManager.default.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.fileSizeKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for entry in entries where !entry.hasDirectoryPath {
                    files.append(entry)
                }
            }
            return files
        }

        private static func sizeMap(for urls: [URL]) -> [URL: Int64] {
            var map: [URL: Int64] = [:]
            for url in urls {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                map[url] = Int64(size)
            }
            return map
        }
    }
}
