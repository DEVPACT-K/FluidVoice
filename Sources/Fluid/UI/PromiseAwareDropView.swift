import AppKit
import SwiftUI

/// Accepts concrete file URLs and file-promise drags (e.g. Voice Memos), resolving promises into per-item staging dirs. Strategy/staging/filtering logic lives in `PromiseDropSupport`.
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

        /// static so in-flight resolution survives the view being destroyed mid-drop
        private static let promiseQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
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

        /// needed in `.overlay`; drops still arrive since drag dispatch doesn't consult hitTest
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
                  !urls.isEmpty
            else {
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
            let onFiles = self.onFiles // captured by value: resolution must outlive this view if destroyed mid-drop
            let onError = self.onError

            // A main-thread pasteboard read can freeze the system-wide drag session, so this returns
            // immediately and every read happens on a background thread.
            let state = ResolutionState()
            state.beginInFlight() // outer worker token, released when it finishes

            Task { @MainActor in // poller starts before any pasteboard read so a hung first read still hits a timeout
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

                // Step 1: snapshot receivers and per-item bytes. NSPasteboard isn't thread-safe and
                // receivePromisedFiles touches it from its own queue, so every read must finish first.
                var receivers: [NSFilePromiseReceiver] = []
                var suggestedName: String?
                var promisedTypeID: String?
                var itemPayloads: [(name: String?, data: Data)] = []
                let readError = FluidCatchObjCException {
                    receivers = (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
                    suggestedName = pasteboard.string(
                        forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-suggested-file-name")
                    )
                    promisedTypeID = pasteboard.string(
                        forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")
                    )
                    for item in pasteboard.pasteboardItems ?? [] {
                        guard let itemTypeID = item.string(
                            forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")
                        ) ?? promisedTypeID else { continue }
                        guard let data = item.data(forType: NSPasteboard.PasteboardType(itemTypeID)),
                              !data.isEmpty else { continue }
                        let name = item.string(
                            forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-suggested-file-name")
                        )
                        itemPayloads.append((name: name, data: data))
                    }
                }
                if let readError {
                    DebugLogger.shared.warning(
                        "Pasteboard read raised: \(readError)",
                        source: "PromiseAwareDropView"
                    )
                }
                DebugLogger.shared.debug(
                    "Promise drop [receivers=\(receivers.count), items=\(itemPayloads.count), type=\(promisedTypeID ?? "?"), name=\(suggestedName ?? "?")]",
                    source: "PromiseAwareDropView"
                )
                state.setPayloadCount(itemPayloads.count)

                // Step 2: raw-data fallback (the reliable path for Voice Memos), disambiguating same-named items.
                if let dataDir, !itemPayloads.isEmpty {
                    var usedNames = Set<String>()
                    for (index, payload) in itemPayloads.enumerated() {
                        let fallbackName = "Dropped Audio \(index + 1)"
                        let itemName = PromiseDropSupport.sanitizedFileName( // provider-supplied name is untrusted: separators would escape staging
                            payload.name ?? suggestedName,
                            fallback: fallbackName
                        )
                        var fileName = itemName
                        var counter = 2
                        while usedNames.contains(fileName) {
                            let base = (itemName as NSString).deletingPathExtension
                            let ext = (itemName as NSString).pathExtension
                            fileName = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                            counter += 1
                        }
                        usedNames.insert(fileName)
                        let target = dataDir.appendingPathComponent(fileName)
                        do {
                            try payload.data.write(to: target)
                            DebugLogger.shared.debug(
                                "Raw-data fallback wrote \(payload.data.count) bytes to \(target.lastPathComponent)",
                                source: "PromiseAwareDropView"
                            )
                        } catch {
                            DebugLogger.shared.debug(
                                "Raw-data fallback write failed: \(error.localizedDescription)",
                                source: "PromiseAwareDropView"
                            )
                        }
                    }
                }

                // Step 3: modern receivers. Still required once raw-data delivered — an unresolved promise
                // wedges Voice Memos's drag machinery until restart.
                for receiver in receivers {
                    guard let dir = try? session.makeItemDirectory() else { continue }
                    // Both decode promise metadata and can raise (the OS refuses a Voice Memos NSCalendarDate);
                    // uncaught, that aborts the process, so a bad promise must degrade to the fallbacks.
                    var promisedFiles = 0
                    let nameError = FluidCatchObjCException { promisedFiles = receiver.fileNames.count }
                    if let nameError {
                        DebugLogger.shared.warning(
                            "Modern promise receiver raised reading fileNames: \(nameError)",
                            source: "PromiseAwareDropView"
                        )
                        try? FileManager.default.removeItem(at: dir) // nothing started writing here, and registering it would inflate the expected count
                        continue
                    }
                    state.registerReceiverDir(dir, promisedFileCount: promisedFiles)

                    state.beginReceiver() // released once, after the receiver's LAST file callback
                    let completion = ReceiverCompletion(fileCount: promisedFiles)
                    let startError = FluidCatchObjCException {
                        receiver.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: Self.promiseQueue) { url, error in
                            if let error {
                                DebugLogger.shared.debug(
                                    "Modern promise receiver failed [\(url.lastPathComponent)]: \(error.localizedDescription)",
                                    source: "PromiseAwareDropView"
                                )
                            }
                            guard completion.recordFile(failed: error != nil) else { return }
                            // Failed dirs are never delivered, so only one that produced nothing counts as failed.
                            let produced = !(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty)
                            if completion.anyFailed, !produced {
                                state.markFailed(dir)
                            } else {
                                state.markCompleted(dir)
                            }
                            state.endReceiver()
                        }
                    }
                    if let startError {
                        DebugLogger.shared.warning(
                            "Modern promise receiver raised on start: \(startError)",
                            source: "PromiseAwareDropView"
                        )
                        if completion.abort() { // callbacks may already have resolved the dir and released the token
                            state.markRaised(dir)
                            state.endReceiver()
                        }
                    }
                }

                // Step 4: legacy fallback, last resort only — an eager call blocks Voice Memos for 35-80s.
                // Called by string selector to dodge the deprecation warning.
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
                            var names: [String] = []
                            let legacyError = FluidCatchObjCException {
                                names = (
                                    sender.perform(Selector(("namesOfPromisedFilesDroppedAtDestination:")), with: legacyDir)?
                                        .takeUnretainedValue() as? [String]
                                ) ?? []
                            }
                            if let legacyError {
                                DebugLogger.shared.warning(
                                    "Legacy promise call raised: \(legacyError)",
                                    source: "PromiseAwareDropView"
                                )
                            }
                            DebugLogger.shared.debug(
                                "Legacy promise names: \(names)",
                                source: "PromiseAwareDropView"
                            )
                            state.setLegacyNameCount(names.count) // on a legacy-only drop this is the sole record of how many files to expect
                        }
                    }
                }
            }
            return true
        }

        /// `receivePromisedFiles` fires once per name, so count down to release the receiver's in-flight token exactly once.
        private final class ReceiverCompletion: @unchecked Sendable {
            private let lock = NSLock()
            private var remaining: Int
            private(set) var anyFailed = false

            init(fileCount: Int) {
                self.remaining = max(fileCount, 1) // guard a zero/nil name count: it must still count down to zero
            }

            /// true exactly once, for the last file this receiver reports
            func recordFile(failed: Bool) -> Bool {
                self.lock.lock()
                defer { self.lock.unlock() }
                if failed { self.anyFailed = true }
                guard self.remaining > 0 else { return false } // a provider can over-fire, or fire after an abort
                self.remaining -= 1
                return self.remaining <= 0
            }

            func abort() -> Bool {
                self.lock.lock()
                defer { self.lock.unlock() }
                guard self.remaining > 0 else { return false }
                self.remaining = 0
                self.anyFailed = true
                return true
            }
        }

        /// Shared between the delivery threads and the main-actor poller: which dirs resolved, what is in flight.
        private final class ResolutionState: @unchecked Sendable {
            private let lock = NSLock()
            private var receiverDirs: [URL] = []
            private var completed: Set<URL> = []
            private var failed: Set<URL> = []
            private var raised: Set<URL> = []
            private var inFlightCount = 0
            private var receiverInFlightCount = 0
            private var payloadCount = 0
            private var promisedFileCount = 0
            private var legacyNameCount = 0

            /// One receiver can promise several files, so the name count — not the dir count — is what the drop yields.
            func registerReceiverDir(_ dir: URL, promisedFileCount: Int) {
                self.lock.lock()
                defer { self.lock.unlock() }
                self.receiverDirs.append(dir)
                self.promisedFileCount += max(promisedFileCount, 1)
            }

            func promisedFileCountValue() -> Int {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.promisedFileCount
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

            /// already answered, so unlike pending its dir is safe to sweep immediately
            func markFailed(_ dir: URL) {
                self.lock.lock()
                defer { self.lock.unlock() }
                self.failed.insert(dir)
            }

            /// Resolved, but the receiver raised mid-flight and may still be writing: defer the cleanup.
            func markRaised(_ dir: URL) {
                self.lock.lock()
                defer { self.lock.unlock() }
                self.failed.insert(dir)
                self.raised.insert(dir)
            }

            func failedSnapshot() -> Set<URL> {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.failed
            }

            func raisedSnapshot() -> Set<URL> {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.raised
            }

            func setLegacyNameCount(_ count: Int) {
                self.lock.lock()
                defer { self.lock.unlock() }
                self.legacyNameCount = count
            }

            func legacyNameCountValue() -> Int {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.legacyNameCount
            }

            /// lets a receiver-less multi-item drop still detect a partial delivery
            func setPayloadCount(_ count: Int) {
                self.lock.lock()
                defer { self.lock.unlock() }
                self.payloadCount = count
            }

            func payloadCountValue() -> Int {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.payloadCount
            }

            /// Fallback writers only — an uncancelled receiver never releases, so it must not gate delivery.
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

            func beginReceiver() {
                self.lock.lock()
                defer { self.lock.unlock() }
                self.receiverInFlightCount += 1
            }

            func endReceiver() {
                self.lock.lock()
                defer { self.lock.unlock() }
                self.receiverInFlightCount -= 1
            }
        }

        /// user-initiated QoS: default-QoS threads starve while ML inference saturates the cores
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
            let hardTimeout: TimeInterval = 120 // a provider can take 60s+ under heavy load (seen up to 80s) before a truly wedged one errors out
            let modernGrace: TimeInterval = 1.5 // long enough for a working receiver to write its first byte
            let start = Date()

            func makeContext() -> DeliveryContext {
                let receiverDirs = state.receiverDirsSnapshot()
                let completed = state.completedSnapshot()
                let failed = state.failedSnapshot()
                let raised = state.raisedSnapshot()
                return DeliveryContext(
                    allDirs: receiverDirs + [legacyDir, dataDir].compactMap(\.self),
                    pendingReceiverDirs: receiverDirs.filter { !completed.contains($0) && (!failed.contains($0) || raised.contains($0)) },
                    pendingFallbackDirs: state.hasInFlightWork ? [legacyDir].compactMap(\.self) : [], // relocation empties the legacy dir, so a sweep would see it as undelivered and delete a destination still being written
                    totalExpected: max(state.promisedFileCountValue(), state.payloadCountValue(), state.legacyNameCountValue(), 1),
                    session: session,
                    onFiles: onFiles,
                    onError: onError
                )
            }

            var fallbackPrevSizes: [URL: Int64] = [:]

            while true {
                let elapsed = Date().timeIntervalSince(start)
                if elapsed >= hardTimeout { break }

                let receiverDirs = state.receiverDirsSnapshot() // a receiver dir only counts once its completion callback fired, never just from a stable size
                let readyModernDirs = state.completedSnapshot()
                let failedModernDirs = state.failedSnapshot()
                let modernFiles = self.listFiles(in: receiverDirs.filter(readyModernDirs.contains))
                let legacyFiles = self.listFiles(in: [legacyDir].compactMap(\.self))
                let dataFiles = self.listFiles(in: [dataDir].compactMap(\.self))
                let fallbackSizes = self.sizeMap(for: legacyFiles + dataFiles)

                // Receivers aren't counted as in-flight work (an uncancelled one never releases), so a slow
                // provider — 80s has been seen — is kept alive by its files instead, not by a token.
                let unresolvedDirs = receiverDirs.filter { !readyModernDirs.contains($0) && !failedModernDirs.contains($0) }
                let receiversProducing = unresolvedDirs.contains { !self.listFiles(in: [$0]).isEmpty }
                if elapsed >= softTimeout, !state.hasInFlightWork, !receiversProducing { break }

                let resolvedCount = readyModernDirs.count + failedModernDirs.count
                let allReceiversResolved = !receiverDirs.isEmpty && resolvedCount >= receiverDirs.count

                let modernComplete = allReceiversResolved && !readyModernDirs.isEmpty && !modernFiles.isEmpty // every receiver resolved, at least one completed, files produced
                if modernComplete {
                    self.deliver(modern: modernFiles, legacy: legacyFiles, data: dataFiles, context: makeContext())
                    return
                }

                // Voice Memos only cancels a receiver when the NEXT drag starts, so a lone drop's stays unresolved
                // forever. One that has written nothing past the grace is non-producing; mid-transfer still holds.
                let receiversStalled = elapsed > modernGrace && !receiversProducing

                let modernExhaustedWithNoWins = receiverDirs.isEmpty
                    || ((allReceiversResolved || receiversStalled) && readyModernDirs.isEmpty)
                let modernProducedNothing = modernExhaustedWithNoWins && elapsed > modernGrace
                let fallbackStable = !fallbackSizes.isEmpty && fallbackSizes == fallbackPrevSizes
                    && !state.hasInFlightWork // worker fully done, so a multi-item sweep still writing later files isn't delivered early
                if modernProducedNothing, fallbackStable {
                    self.deliver(modern: [], legacy: legacyFiles, data: dataFiles, context: makeContext())
                    return
                }

                fallbackPrevSizes = fallbackSizes
                try? await Task.sleep(nanoseconds: pollInterval)
            }

            let receiverDirs = state.receiverDirsSnapshot() // timeout: deliver whatever completed; incomplete dirs are excluded and surface via the partial-failure error
            let readyModernDirs = state.completedSnapshot()
            self.deliver(
                modern: self.listFiles(in: receiverDirs.filter(readyModernDirs.contains)),
                legacy: self.listFiles(in: [legacyDir].compactMap(\.self)),
                data: self.listFiles(in: [dataDir].compactMap(\.self)),
                context: makeContext()
            )
        }

        private struct DeliveryContext {
            let allDirs: [URL]
            // Never swept at delivery: deleting an in-flight promise's destination wedges Voice Memos.
            let pendingReceiverDirs: [URL]
            let pendingFallbackDirs: [URL]
            let totalExpected: Int
            let session: PromiseDropSupport.StagingSession
            let onFiles: ([(url: URL, stagingDir: URL?)]) -> Void
            let onError: (String) -> Void
        }

        private static func deliver( // selection/dedup lives in `PromiseDropSupport.selectDelivery`
            modern: [URL],
            legacy: [URL],
            data: [URL],
            context: DeliveryContext
        ) {
            DebugLogger.shared.debug(
                "Promise delivery [modern=\(modern.count), legacy=\(legacy.count), data=\(data.count), expected=\(context.totalExpected)]",
                source: "PromiseAwareDropView"
            )
            let selected = PromiseDropSupport.selectDelivery(
                modern: modern,
                legacy: legacy,
                data: data,
                expectedItemCount: context.totalExpected
            )
            let supported = PromiseDropSupport.filterSupported(selected)
            let result = PromiseDropSupport.relocateForExclusiveOwnership(supported, session: context.session) // any path can land several files in one dir; the coordinator deletes per item

            if result.isEmpty {
                for dir in PromiseDropSupport.dirsSafeToRemoveNow( // must not delete dirs whose receiver promise hasn't completed — wedges the source app's drag machinery
                    allDirs: context.allDirs,
                    deliveredFiles: [],
                    pendingDirs: context.pendingReceiverDirs + context.pendingFallbackDirs
                ) {
                    try? FileManager.default.removeItem(at: dir)
                }
                if context.pendingReceiverDirs.isEmpty, context.pendingFallbackDirs.isEmpty {
                    context.session.removeAll()
                } else {
                    self.cleanUpLater(pendingDirs: context.pendingReceiverDirs + context.pendingFallbackDirs)
                }
                let reason = selected.isEmpty
                    ? "No files could be read from the drop."
                    : "The dropped files are not a supported format."
                context.onError("\(reason) \(MeetingTranscriptionService.dropErrorCopy)")
                return
            }

            // Dirs holding no delivered file are dead weight; racing a writer here is harmless, they're copies.
            for dir in PromiseDropSupport.dirsSafeToRemoveNow(
                allDirs: context.allDirs,
                deliveredFiles: result.map(\.url),
                pendingDirs: context.pendingReceiverDirs + context.pendingFallbackDirs
            ) {
                try? FileManager.default.removeItem(at: dir)
            }

            context.onFiles(result)
            if result.count < context.totalExpected {
                context.onError("\(context.totalExpected - result.count) file(s) could not be read from the drop.")
            }

            self.cleanUpLater(pendingDirs: context.pendingReceiverDirs + context.pendingFallbackDirs)
        }

        private static func cleanUpLater(pendingDirs: [URL]) {
            guard !pendingDirs.isEmpty else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                for dir in pendingDirs {
                    try? FileManager.default.removeItem(at: dir)
                }
                for parent in Set(pendingDirs.map { $0.deletingLastPathComponent() })
                    where parent.lastPathComponent.hasPrefix(PromiseDropSupport.stagingRootPrefix)
                {
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
