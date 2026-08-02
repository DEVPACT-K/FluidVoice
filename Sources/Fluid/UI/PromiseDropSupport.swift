import AVFoundation
import Foundation
import UniformTypeIdentifiers

// Testable, nonisolated core logic for the promise-aware drop path (pasteboard strategy, staging, format filtering); `PromiseAwareDropView` owns the live drag session.
nonisolated enum PromiseDropSupport {
    enum Strategy: Equatable {
        case concreteFileURLs
        case filePromise
    }

    private static let concreteFileURLType = "public.file-url"

    // Voice Memos emits a mix of these; any one is sufficient.
    private static let filePromiseTypes: Set<String> = [
        "com.apple.NSFilePromiseItemMetaData",
        "com.apple.pasteboard.promised-file-content-type",
        "Apple files promise pasteboard type",
    ]

    // Concrete URLs win; a promise needs advertised audio/movie content, so a Photos image promise is rejected.
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

    // Compares standardized *paths*: trailing-slash differences once made equal dirs compare unequal.
    static func sweepableDirs(allDirs: [URL], deliveredFiles: [URL]) -> [URL] {
        let deliveredDirPaths = Set(deliveredFiles.map {
            $0.deletingLastPathComponent().standardizedFileURL.path
        })
        return allDirs.filter { !deliveredDirPaths.contains($0.standardizedFileURL.path) }
    }

    // Deleting an in-flight promise's destination wedges the source app's drag machinery until restart.
    static func dirsSafeToRemoveNow(allDirs: [URL], deliveredFiles: [URL], pendingDirs: [URL]) -> [URL] {
        let pendingPaths = Set(pendingDirs.map { $0.standardizedFileURL.path })
        return sweepableDirs(allDirs: allDirs, deliveredFiles: deliveredFiles)
            .filter { !pendingPaths.contains($0.standardizedFileURL.path) }
    }

    // Separators or `..` would let `appendingPathComponent` write outside staging.
    static func sanitizedFileName(_ rawName: String?, fallback: String) -> String {
        guard let rawName else { return fallback }
        let lastComponent = (rawName as NSString).lastPathComponent
        let trimmed = lastComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        // ("/" as NSString).lastPathComponent is "/", so it survives the reduction above
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/") else {
            return fallback
        }
        return trimmed
    }

    // Merges the three promise-delivery paths: every modern file is delivered; legacy/raw-data only fill gaps, bounded by `expectedItemCount`.
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

    // The coordinator deletes an item's dir the moment it finishes, so each file needs its own.
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

    private static let supportedExtensions: Set<String> = {
        let avTypes = AVURLAsset.audiovisualTypes()
        let extensions = avTypes.compactMap { fileType -> String? in
            guard let utType = UTType(fileType.rawValue) else { return nil }
            guard utType.conforms(to: .audio) || utType.conforms(to: .movie) else { return nil }
            return utType.preferredFilenameExtension?.lowercased()
        }
        return Set(extensions)
    }()

    static func filterSupported(_ urls: [URL]) -> [URL] {
        return urls.filter { url in
            let ext = url.pathExtension.lowercased()
            return !ext.isEmpty && supportedExtensions.contains(ext)
        }
    }

    // Prefix of every staging root; the batch coordinator uses it to prune empty roots once its item dir is gone.
    static let stagingRootPrefix = "PromiseDrop-"

    // Each promised file gets its own subdirectory so identically-named files never collide.
    final class StagingSession: Sendable {
        private let root: URL

        init() throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(PromiseDropSupport.stagingRootPrefix)\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        }

        func makeItemDirectory() throws -> URL {
            let dir = self.root.appendingPathComponent("item-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        func removeAll() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }
}
