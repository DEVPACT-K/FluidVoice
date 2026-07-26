import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Testable, nonisolated core logic for the promise-aware drop path (issue #219).
///
/// The AppKit drop view (`PromiseAwareDropView`) needs a live drag session, so it
/// delegates the pure pieces here: deciding whether a pasteboard carries concrete
/// file URLs or file promises, staging promised files into collision-free per-item
/// directories, and filtering drops to formats AVFoundation can actually decode.
/// Everything is `nonisolated` so it can be unit-tested from a nonisolated test
/// context despite the app target's `MainActor` default actor isolation.
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

    /// Pasteboard type identifiers that signal a file-promise drop. Voice Memos
    /// emits a mix of these (verified live 2026-07-25); any one is sufficient.
    private static let filePromiseTypes: Set<String> = [
        "com.apple.NSFilePromiseItemMetaData",
        "com.apple.pasteboard.promised-file-content-type",
        "Apple files promise pasteboard type",
    ]

    /// Decides the drop strategy from raw pasteboard type strings.
    ///
    /// Concrete file URLs win over promises when both are present. Promises are
    /// only accepted when the pasteboard also advertises an audio/movie content
    /// type (Voice Memos exposes e.g. `com.apple.m4a-audio` directly in the
    /// type list) — so an image promise from Photos is rejected up front rather
    /// than staged and failed later. Returns `nil` for pasteboards that carry
    /// neither file URLs nor decodable promises.
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

    /// Staging dirs that hold no delivered file and should be swept.
    ///
    /// Compares standardized *paths*, not URLs: a directory built via
    /// `appendingPathComponent` and the same directory derived from a file via
    /// `deletingLastPathComponent()` differ in trailing-slash form and compare
    /// unequal as URLs — which once made the sweep delete a delivered file.
    static func sweepableDirs(allDirs: [URL], deliveredFiles: [URL]) -> [URL] {
        let deliveredDirPaths = Set(deliveredFiles.map {
            $0.deletingLastPathComponent().standardizedFileURL.path
        })
        return allDirs.filter { !deliveredDirPaths.contains($0.standardizedFileURL.path) }
    }

    /// Merges the three promise-delivery paths into the final file list.
    ///
    /// Every modern-receiver file is delivered: each receiver stages into its own
    /// directory, so two distinct memos that share a display name (e.g. two
    /// "New Recording.m4a") are distinct files and must never be collapsed.
    /// Legacy and raw-data files are alternates of the same dragged items, so
    /// they only contribute names the delivered set doesn't already contain.
    static func selectDelivery(modern: [URL], legacy: [URL], data: [URL]) -> [URL] {
        var delivered = modern
        var names = Set(modern.map(\.lastPathComponent))
        for url in legacy + data where !names.contains(url.lastPathComponent) {
            delivered.append(url)
            names.insert(url.lastPathComponent)
        }
        return delivered
    }

    /// Audio/movie file extensions the OS can decode, queried nonisolated from
    /// AVFoundation. Mirrors `MeetingTranscriptionService.supportedFileExtensions`
    /// but is safe to call from any isolation context.
    private static let supportedExtensions: Set<String> = {
        let avTypes = AVURLAsset.audiovisualTypes()
        let extensions = avTypes.compactMap { fileType -> String? in
            guard let utType = UTType(fileType.rawValue) else { return nil }
            guard utType.conforms(to: .audio) || utType.conforms(to: .movie) else { return nil }
            return utType.preferredFilenameExtension?.lowercased()
        }
        return Set(extensions)
    }()

    /// Keeps only URLs whose (lowercased) extension is a decodable audio/movie
    /// format. Order-preserving.
    static func filterSupported(_ urls: [URL]) -> [URL] {
        return urls.filter { url in
            let ext = url.pathExtension.lowercased()
            return !ext.isEmpty && supportedExtensions.contains(ext)
        }
    }

    /// A scratch directory tree under the user temp dir that gives each promised
    /// file its own subdirectory, so identically-named files (e.g. several Voice
    /// Memos drops named "New Recording.m4a") never collide.
    ///
    /// All state is immutable, so the session is `Sendable` and safe to share
    /// across the main actor and the background queue that resolves promises.
    /// Prefix of every drop-session staging root; the batch coordinator uses it
    /// to recognize (and prune) empty session roots after item cleanup.
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
