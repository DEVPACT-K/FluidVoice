import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Testable, nonisolated core logic for the promise-aware drop path: pasteboard strategy
/// detection, collision-free per-item staging, and AVFoundation format filtering.
/// `PromiseAwareDropView` owns the live drag session and delegates the pure pieces here.
/// `nonisolated` so it's unit-testable despite the app target's `MainActor` default.
nonisolated enum PromiseDropSupport {
    /// How a given pasteboard should be interpreted.
    enum Strategy: Equatable {
        /// Concrete file URLs are present (`public.file-url`).
        case concreteFileURLs
        /// Only file-promise metadata is present (e.g. a Voice Memos drag).
        case filePromise
    }

    /// The pasteboard type that carries a concrete file URL.
    private static let concreteFileURLType = "public.file-url"

    /// Pasteboard types signaling a file-promise drop. Voice Memos emits a mix of these;
    /// any one is sufficient.
    private static let filePromiseTypes: Set<String> = [
        "com.apple.NSFilePromiseItemMetaData",
        "com.apple.pasteboard.promised-file-content-type",
        "Apple files promise pasteboard type",
    ]

    /// Concrete file URLs win when both are present. Promises are only accepted when the
    /// pasteboard also advertises audio/movie content (Voice Memos exposes e.g.
    /// `com.apple.m4a-audio` directly), so an image promise from Photos is rejected up
    /// front instead of staged and failed later. `nil` if neither is present.
    static func strategy(forPasteboardTypes types: [String]) -> Strategy? {
        if types.contains(concreteFileURLType) {
            return .concreteFileURLs
        }
        guard types.contains(where: { filePromiseTypes.contains($0) }) else {
            return nil
        }
        let promisesAudioVisualContent = types.contains { type in
            guard let utType = UTType(type) else { return false }
            return utType.conforms(to: .audio) || utType.conforms(to: .movie)
        }
        return promisesAudioVisualContent ? .filePromise : nil
    }

    /// Staging dirs that hold no delivered file and should be swept. Compares standardized
    /// *paths*, not URLs — trailing-slash differences between `appendingPathComponent` and
    /// `deletingLastPathComponent()` once made two equal dirs compare unequal as URLs.
    static func sweepableDirs(allDirs: [URL], deliveredFiles: [URL]) -> [URL] {
        let deliveredDirPaths = Set(deliveredFiles.map {
            $0.deletingLastPathComponent().standardizedFileURL.path
        })
        return allDirs.filter { !deliveredDirPaths.contains($0.standardizedFileURL.path) }
    }

    /// Dirs safe to delete now: `sweepableDirs` minus any dir whose receiver promise
    /// hasn't completed. Deleting an in-flight `NSFilePromiseReceiver`'s destination
    /// wedges the source app's drag machinery until restart; callers defer removal
    /// of excluded dirs until the pending promise resolves.
    static func dirsSafeToRemoveNow(allDirs: [URL], deliveredFiles: [URL], pendingDirs: [URL]) -> [URL] {
        let pendingPaths = Set(pendingDirs.map { $0.standardizedFileURL.path })
        return sweepableDirs(allDirs: allDirs, deliveredFiles: deliveredFiles)
            .filter { !pendingPaths.contains($0.standardizedFileURL.path) }
    }

    /// Reduces a drag-source-supplied name to one safe path component; separators or
    /// `..` would otherwise let `appendingPathComponent` write outside staging.
    /// Unusable names (empty, `.`, `..`, all-separators) take the caller's fallback.
    static func sanitizedFileName(_ rawName: String?, fallback: String) -> String {
        guard let rawName else { return fallback }
        let lastComponent = (rawName as NSString).lastPathComponent
        let trimmed = lastComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        // ("/" as NSString).lastPathComponent is "/", so it survives the reduction.
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/") else {
            return fallback
        }
        return trimmed
    }

    /// Merges the three promise-delivery paths. Every modern-receiver file is delivered
    /// (each stages into its own dir, so same-named memos are distinct files, never
    /// collapsed). Legacy/raw-data files are alternates, not extras, so they only fill
    /// gaps; since the raw-data path renames same-named items, names alone can't identify
    /// an alternate, so `expectedItemCount` bounds the result (nil keeps name-only behavior).
    static func selectDelivery(
        modern: [URL],
        legacy: [URL],
        data: [URL],
        expectedItemCount: Int? = nil
    ) -> [URL] {
        var delivered = modern
        var names = Set(modern.map(\.lastPathComponent))
        for url in legacy + data where !names.contains(url.lastPathComponent) {
            if let expectedItemCount, delivered.count >= expectedItemCount { break }
            delivered.append(url)
            names.insert(url.lastPathComponent)
        }
        return delivered
    }

    /// Gives each delivered file its own dir: the coordinator deletes an item's dir the
    /// moment that item finishes, so a shared one loses files still-queued items need.
    /// A failed move reports `stagingDir: nil` — unowned beats shared. Order-preserving.
    static func relocateForExclusiveOwnership(
        _ files: [URL],
        session: StagingSession,
        makeDirectory: (StagingSession) throws -> URL = { try $0.makeItemDirectory() },
        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) -> [(url: URL, stagingDir: URL?)] {
        files.map { file in
            do {
                let dir = try makeDirectory(session)
                let destination = dir.appendingPathComponent(file.lastPathComponent)
                try move(file, destination)
                return (url: destination, stagingDir: dir)
            } catch {
                return (url: file, stagingDir: nil)
            }
        }
    }

    /// Audio/movie extensions the OS can decode. Mirrors
    /// `MeetingTranscriptionService.supportedFileExtensions` but callable from any isolation.
    private static let supportedExtensions: Set<String> = {
        let avTypes = AVURLAsset.audiovisualTypes()
        let extensions = avTypes.compactMap { fileType -> String? in
            guard let utType = UTType(fileType.rawValue) else { return nil }
            guard utType.conforms(to: .audio) || utType.conforms(to: .movie) else { return nil }
            return utType.preferredFilenameExtension?.lowercased()
        }
        return Set(extensions)
    }()

    /// Keeps only URLs with a decodable audio/movie extension. Order-preserving.
    static func filterSupported(_ urls: [URL]) -> [URL] {
        return urls.filter { url in
            let ext = url.pathExtension.lowercased()
            return !ext.isEmpty && supportedExtensions.contains(ext)
        }
    }

    /// Scratch directory tree under the user temp dir; each promised file gets its own
    /// subdirectory so identically-named files never collide. Immutable state makes the
    /// session `Sendable`, safe to share between the main actor and the resolution queue.
    /// Prefix of every staging root; the batch coordinator uses it to prune empty roots.
    static let stagingRootPrefix = "PromiseDrop-"

    final class StagingSession: Sendable {
        private let root: URL

        /// Creates a unique root directory under the user temp dir.
        init() throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(PromiseDropSupport.stagingRootPrefix)\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        }

        /// Creates a fresh, unique subdirectory for a single promised item.
        func makeItemDirectory() throws -> URL {
            let dir = self.root.appendingPathComponent("item-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        /// Deletes the whole staging tree.
        func removeAll() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }
}
