import Foundation
import TranscribeCpp

enum TranscribeCppLongFormProcessor {
    static func ranges(
        sampleCount: Int,
        sampleRate: Int,
        maximumChunkSeconds: Double = 30,
        overlapSeconds: Double = 2
    ) -> [Range<Int>] {
        guard sampleCount > 0, sampleRate > 0, maximumChunkSeconds > 0 else { return [] }

        let maximumChunkSamples = max(1, Int(Double(sampleRate) * maximumChunkSeconds))
        guard sampleCount > maximumChunkSamples else { return [0..<sampleCount] }

        let requestedOverlap = max(0, Int(Double(sampleRate) * overlapSeconds))
        let overlapSamples = min(requestedOverlap, maximumChunkSamples - 1)
        var ranges: [Range<Int>] = []
        var start = 0

        while start < sampleCount {
            let end = min(start + maximumChunkSamples, sampleCount)
            ranges.append(start..<end)
            guard end < sampleCount else { break }
            start = end - overlapSamples
        }

        return ranges
    }

    static func merge(_ texts: [String]) -> String {
        texts.reduce(into: "") { result, text in
            let next = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !next.isEmpty else { return }
            guard !result.isEmpty else {
                result = next
                return
            }

            if let merged = self.mergeCJK(left: result, right: next) {
                result = merged
                return
            }

            let leftTokens = result.split(whereSeparator: \.isWhitespace).map(String.init)
            let rightTokens = next.split(whereSeparator: \.isWhitespace).map(String.init)
            let overlap = self.wordOverlap(left: leftTokens, right: rightTokens)
            let remaining = rightTokens.dropFirst(overlap)
            guard !remaining.isEmpty else { return }
            result += " " + remaining.joined(separator: " ")
        }
    }

    private static func wordOverlap(left: [String], right: [String]) -> Int {
        let maximum = min(24, left.count, right.count)
        guard maximum > 0 else { return 0 }
        let normalizedLeft = left.map(self.normalize)
        let normalizedRight = right.map(self.normalize)

        for count in stride(from: maximum, through: 1, by: -1) {
            let leftStart = normalizedLeft.count - count
            let matches = (0..<count).allSatisfy {
                !normalizedLeft[leftStart + $0].isEmpty
                    && normalizedLeft[leftStart + $0] == normalizedRight[$0]
            }
            guard matches else { continue }
            if count > 1 || normalizedRight[0].count >= 4 || Int(normalizedRight[0]) != nil {
                return count
            }
        }

        for count in stride(from: maximum, through: 2, by: -1) {
            let leftStart = normalizedLeft.count - count
            let similarCount = (0..<count).reduce(into: 0) { total, index in
                if self.tokensAreSimilar(normalizedLeft[leftStart + index], normalizedRight[index]) {
                    total += 1
                }
            }
            if similarCount >= max(2, count - 1) {
                return count
            }
        }

        var bestRightCount = 0
        var bestMatchLength = 0
        for leftCount in 2...maximum {
            let leftPhrase = self.normalize(left.suffix(leftCount).joined())
            for rightCount in 2...maximum {
                let rightPhrase = self.normalize(right.prefix(rightCount).joined())
                let matchLength = min(leftPhrase.count, rightPhrase.count)
                guard matchLength >= 12 else { continue }
                let distanceLimit = max(2, matchLength / 6)
                guard abs(leftPhrase.count - rightPhrase.count) <= distanceLimit,
                      self.editDistance(leftPhrase, rightPhrase, limit: distanceLimit) <= distanceLimit
                else { continue }
                if matchLength > bestMatchLength {
                    bestMatchLength = matchLength
                    bestRightCount = rightCount
                }
            }
        }

        return bestRightCount
    }

    private static func normalize(_ token: String) -> String {
        token.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func tokensAreSimilar(_ left: String, _ right: String) -> Bool {
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        if min(left.count, right.count) >= 5, left.hasPrefix(right) || right.hasPrefix(left) {
            return true
        }
        let maximumDistance = max(left.count, right.count) >= 8 ? 2 : 1
        return self.editDistance(left, right, limit: maximumDistance) <= maximumDistance
    }

    private static func editDistance(_ left: String, _ right: String, limit: Int) -> Int {
        let lhs = Array(left)
        let rhs = Array(right)
        guard abs(lhs.count - rhs.count) <= limit else { return limit + 1 }
        var previous = Array(0...rhs.count)

        for (leftIndex, leftCharacter) in lhs.enumerated() {
            var current = [leftIndex + 1] + Array(repeating: 0, count: rhs.count)
            var rowMinimum = current[0]
            for (rightIndex, rightCharacter) in rhs.enumerated() {
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                )
                rowMinimum = min(rowMinimum, current[rightIndex + 1])
            }
            if rowMinimum > limit { return limit + 1 }
            previous = current
        }

        return previous[rhs.count]
    }

    private static func mergeCJK(left: String, right: String) -> String? {
        guard self.containsCJK(String(left.suffix(32))),
              self.containsCJK(String(right.prefix(32)))
        else { return nil }
        let leftScalars = Array(left.unicodeScalars)
        let rightScalars = Array(right.unicodeScalars)
        let maximum = min(48, leftScalars.count, rightScalars.count)
        for count in stride(from: maximum, through: 1, by: -1)
            where leftScalars.suffix(count).elementsEqual(rightScalars.prefix(count))
        {
            return left + String(String.UnicodeScalarView(rightScalars.dropFirst(count)))
        }
        return left + right
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30ff, 0x3400...0x4dbf, 0x4e00...0x9fff, 0xac00...0xd7af:
                return true
            default:
                return false
            }
        }
    }
}

/// TranscriptionProvider implementation using transcribe.cpp GGUF models.
final class WhisperProvider: TranscriptionProvider {
    var name: String {
        self.selectedModel == .cohereTranscribeSixBit ? "Cohere Transcribe" : "Whisper (Universal)"
    }

    var isAvailable: Bool {
        guard case .success = Self.backendInitialization else { return false }
        if CPUArchitecture.isAppleSilicon {
            return Transcribe.backendAvailable(.metal)
        }
        return Transcribe.backendAvailable(.cpu)
    }

    private static let backendInitialization: Result<Void, Error> = Result {
        try Transcribe.initBackends()
    }

    private let stateLock = NSLock()
    private var model: Model?
    private var session: Session?
    private var ready = false
    private var loadedModelName: String?

    private let overriddenModelDirectory: URL?
    private let urlSession: URLSession

    var modelOverride: SettingsStore.SpeechModel?

    init(modelDirectory: URL? = nil, urlSession: URLSession = .shared, modelOverride: SettingsStore.SpeechModel? = nil) {
        self.overriddenModelDirectory = modelDirectory
        self.urlSession = urlSession
        self.modelOverride = modelOverride
    }

    deinit {
        self.unloadModel()
    }

    var isReady: Bool {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return self.ready
    }

    private var selectedModel: SettingsStore.SpeechModel {
        self.modelOverride ?? SettingsStore.shared.selectedSpeechModel
    }

    private var modelName: String {
        self.selectedModel.transcribeCppModelFile ?? "whisper-base-Q8_0.gguf"
    }

    private var legacyModelName: String? {
        self.selectedModel.legacyWhisperModelFile
    }

    private var modelURL: URL {
        self.modelDirectory.appendingPathComponent(self.modelName)
    }

    private var legacyModelURL: URL? {
        self.legacyModelName.map { self.modelDirectory.appendingPathComponent($0) }
    }

    private var modelDirectory: URL {
        if let overriddenModelDirectory {
            return overriddenModelDirectory
        }
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            preconditionFailure("Could not find caches directory")
        }
        let directoryName = self.selectedModel == .cohereTranscribeSixBit
            ? "CohereTranscribeModels"
            : "WhisperModels"
        return cacheDir.appendingPathComponent(directoryName)
    }

    private var modelDownloadURL: URL? {
        if self.selectedModel == .cohereTranscribeSixBit {
            return URL(
                string: "https://huggingface.co/handy-computer/cohere-transcribe-03-2026-gguf/resolve/main/\(self.modelName)"
            )
        }

        let modelName = self.modelName
        let suffix = "-Q8_0.gguf"
        guard modelName.hasSuffix(suffix) else { return nil }
        let repoName = String(modelName.dropLast(suffix.count))
        return URL(string: "https://huggingface.co/handy-computer/\(repoName)-gguf/resolve/main/\(modelName)")
    }

    private var backend: Backend {
        CPUArchitecture.isAppleSilicon ? .metal : .cpu
    }

    private func unloadModel() {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        self.session = nil
        self.model = nil
        self.ready = false
        self.loadedModelName = nil
    }

    private func currentLoadedModelName() -> String? {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return self.loadedModelName
    }

    private func installModel(_ model: Model, session: Session, modelName: String) {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        self.model = model
        self.session = session
        self.loadedModelName = modelName
        self.ready = true
    }

    private func activeSession() -> Session? {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return self.session
    }

    private func removeLegacyModelIfNeeded() {
        for legacyFile in SettingsStore.SpeechModel.legacyWhisperModelFiles {
            let url = self.modelDirectory.appendingPathComponent(legacyFile)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                DebugLogger.shared.info("WhisperProvider: Removed legacy Whisper cache \(legacyFile)", source: "WhisperProvider")
            } catch {
                DebugLogger.shared.warning(
                    "WhisperProvider: Failed to remove legacy Whisper cache \(legacyFile): \(error.localizedDescription)",
                    source: "WhisperProvider"
                )
            }
        }
    }

    private func removeLegacyCohereCachesIfNeeded(for model: SettingsStore.SpeechModel) {
        guard model == .cohereTranscribeSixBit, self.overriddenModelDirectory == nil,
              let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return }

        let legacyDirectories = [
            cacheDirectory.appendingPathComponent("cohere-transcribe-03-2026-CoreML-6bit", isDirectory: true),
            cacheDirectory.appendingPathComponent("FluidAudio/CompiledCohereModels", isDirectory: true),
        ]
        for directory in legacyDirectories where FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.removeItem(at: directory)
                DebugLogger.shared.info(
                    "WhisperProvider: Removed legacy Cohere cache at \(directory.path)",
                    source: "WhisperProvider"
                )
            } catch {
                DebugLogger.shared.warning(
                    "WhisperProvider: Failed to remove legacy Cohere cache at \(directory.path): \(error.localizedDescription)",
                    source: "WhisperProvider"
                )
            }
        }
    }

    private func isModelFileValid(at url: URL, for targetModel: SettingsStore.SpeechModel) -> Bool {
        guard let expectedModelFile = targetModel.transcribeCppModelFile,
              url.lastPathComponent == expectedModelFile
        else {
            return false
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else {
            return false
        }
        return size.int64Value == targetModel.expectedDownloadBytes
    }

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)? = nil) async throws {
        try Task.checkCancellation()

        let targetModel = self.selectedModel
        let currentModelName = targetModel.transcribeCppModelFile ?? "whisper-base-Q8_0.gguf"

        let loadedModelName = self.currentLoadedModelName()
        if self.isReady, loadedModelName != currentModelName {
            DebugLogger.shared.info(
                "WhisperProvider: Model changed from \(loadedModelName ?? "nil") to \(currentModelName), forcing reload",
                source: "WhisperProvider"
            )
            self.unloadModel()
        }

        guard !self.isReady else { return }

        try Self.backendInitialization.get()
        try self.validateBackendAvailability(for: targetModel)

        try FileManager.default.createDirectory(at: self.modelDirectory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: self.modelURL.path),
           !self.isModelFileValid(at: self.modelURL, for: targetModel)
        {
            DebugLogger.shared.warning(
                "WhisperProvider: Found invalid model file at \(self.modelURL.path); removing to force re-download",
                source: "WhisperProvider"
            )
            try? FileManager.default.removeItem(at: self.modelURL)
        }

        if !FileManager.default.fileExists(atPath: self.modelURL.path) {
            DebugLogger.shared.info("WhisperProvider: Downloading Whisper GGUF model...", source: "WhisperProvider")
            progressHandler?(.preparingDownload)
            try await self.downloadModel { progress in
                progressHandler?(.downloading(progress))
            }
        }

        guard self.isModelFileValid(at: self.modelURL, for: targetModel) else {
            try? FileManager.default.removeItem(at: self.modelURL)
            throw NSError(
                domain: "WhisperProvider",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Whisper model file is missing or corrupted. Please re-download the model."]
            )
        }
        if targetModel.isWhisperModel {
            self.removeLegacyModelIfNeeded()
        }

        let requiredMemoryGB = targetModel.requiredMemoryGB
        let availableMemoryGB = Self.availableMemoryGB()
        DebugLogger.shared.info(
            "WhisperProvider: Memory check - Required: \(String(format: "%.1f", requiredMemoryGB))GB, Available: \(String(format: "%.1f", availableMemoryGB))GB",
            source: "WhisperProvider"
        )

        if availableMemoryGB < requiredMemoryGB {
            let errorMessage = """
            Insufficient memory for \(targetModel.displayName).
            Required: \(String(format: "%.1f", requiredMemoryGB)) GB
            Available: \(String(format: "%.1f", availableMemoryGB)) GB

            Please try a smaller model or close other applications to free up memory.
            """
            DebugLogger.shared.error("WhisperProvider: \(errorMessage)", source: "WhisperProvider")
            throw NSError(
                domain: "WhisperProvider",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: errorMessage]
            )
        }

        DebugLogger.shared.info("WhisperProvider: Loading \(currentModelName) with \(self.backend)", source: "WhisperProvider")
        progressHandler?(.loading)

        let loadedModel = try Model(
            path: self.modelURL.path,
            options: ModelOptions(backend: self.backend)
        )
        let runtimeBackend = loadedModel.backend.lowercased()
        if CPUArchitecture.isAppleSilicon,
           !runtimeBackend.contains("metal"),
           !runtimeBackend.contains("mtl")
        {
            throw NSError(
                domain: "WhisperProvider",
                code: -7,
                userInfo: [NSLocalizedDescriptionKey: "\(targetModel.displayName) loaded on \(loadedModel.backend), but Metal is required on Apple Silicon."]
            )
        }
        let loadedSession = try loadedModel.session()

        try Task.checkCancellation()
        self.installModel(loadedModel, session: loadedSession, modelName: currentModelName)
        self.removeLegacyCohereCachesIfNeeded(for: targetModel)
        DebugLogger.shared.info(
            "WhisperProvider: Model ready (\(currentModelName), backend=\(loadedModel.backend), arch=\(loadedModel.arch))",
            source: "WhisperProvider"
        )
    }

    private func validateBackendAvailability(for model: SettingsStore.SpeechModel) throws {
        if CPUArchitecture.isAppleSilicon, !Transcribe.backendAvailable(.metal) {
            throw NSError(
                domain: "WhisperProvider",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "\(model.displayName) requires the Metal Whisper backend on Apple Silicon."]
            )
        }

        if !CPUArchitecture.isAppleSilicon, !Transcribe.backendAvailable(.cpu) {
            throw NSError(
                domain: "WhisperProvider",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "Whisper CPU backend is unavailable on this Mac."]
            )
        }
    }

    private static func availableMemoryGB() -> Double {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &vmStats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            DebugLogger.shared.warning("WhisperProvider: Failed to get memory stats, assuming sufficient memory", source: "WhisperProvider")
            return 16.0
        }

        let freePages = UInt64(vmStats.free_count)
        let inactivePages = UInt64(vmStats.inactive_count)
        let purgablePages = UInt64(vmStats.purgeable_count)
        let availableBytes = (freePages + inactivePages + purgablePages) * UInt64(pageSize)
        return Double(availableBytes) / (1024 * 1024 * 1024)
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        let minSamples = 16_000
        guard samples.count >= minSamples else {
            throw NSError(
                domain: "WhisperProvider",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Audio too short for transcription"]
            )
        }

        guard let session = self.activeSession() else {
            throw NSError(
                domain: "WhisperProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Speech model not loaded"]
            )
        }

        let isCohere = self.selectedModel == .cohereTranscribeSixBit
        let options = RunOptions(
            timestamps: isCohere ? .none : .segment,
            language: isCohere ? SettingsStore.shared.selectedCohereLanguage.rawValue : nil
        )
        let texts: [String]
        if isCohere {
            let ranges = TranscribeCppLongFormProcessor.ranges(
                sampleCount: samples.count,
                sampleRate: 16_000
            )
            var chunkTexts: [String] = []
            chunkTexts.reserveCapacity(ranges.count)
            for range in ranges {
                try Task.checkCancellation()
                let transcript = try await session.run(Array(samples[range]), options: options)
                chunkTexts.append(transcript.text)
            }
            texts = chunkTexts
        } else {
            texts = try [await session.run(samples, options: options).text]
        }
        let fullText = TranscribeCppLongFormProcessor.merge(texts)
        return ASRTranscriptionResult(text: fullText, confidence: 1.0)
    }

    func modelsExistOnDisk() -> Bool {
        return self.isModelFileValid(at: self.modelURL, for: self.selectedModel)
    }

    func clearCache() async throws {
        let targetModel = self.selectedModel
        self.unloadModel()

        if FileManager.default.fileExists(atPath: self.modelURL.path) {
            try FileManager.default.removeItem(at: self.modelURL)
        }
        if let legacyModelURL, FileManager.default.fileExists(atPath: legacyModelURL.path) {
            try FileManager.default.removeItem(at: legacyModelURL)
        }
        self.removeLegacyModelIfNeeded()

        if FileManager.default.fileExists(atPath: self.modelDirectory.path) {
            let contents = try FileManager.default.contentsOfDirectory(atPath: self.modelDirectory.path)
            if contents.isEmpty {
                try FileManager.default.removeItem(at: self.modelDirectory)
            }
        }
        self.removeLegacyCohereCachesIfNeeded(for: targetModel)
    }

    private func downloadModel(progressHandler: ((Double) -> Void)?) async throws {
        guard let url = self.modelDownloadURL else {
            throw NSError(
                domain: "WhisperProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Whisper model URL"]
            )
        }

        DebugLogger.shared.info("WhisperProvider: Downloading from \(url.absoluteString)", source: "WhisperProvider")

        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            do {
                if attempt == 1 {
                    progressHandler?(0.0)
                }
                try await self.downloadFile(from: url, to: self.modelURL, progressHandler: progressHandler)
                DebugLogger.shared.info("WhisperProvider: Model downloaded successfully", source: "WhisperProvider")
                return
            } catch let error as NSError {
                if Task.isCancelled
                    || (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
                {
                    throw CancellationError()
                }

                let isLastAttempt = attempt == maxAttempts
                if error.domain == NSURLErrorDomain {
                    let message: String
                    switch error.code {
                    case NSURLErrorNotConnectedToInternet:
                        message = "No internet connection. Please connect to the internet to download the Whisper model."
                    case NSURLErrorTimedOut:
                        message = "Download timed out. Please check your internet connection and try again."
                    case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                        message = "Cannot reach download server. Please check your internet connection."
                    default:
                        message = "Network error: \(error.localizedDescription)"
                    }

                    if isLastAttempt {
                        throw NSError(
                            domain: "WhisperProvider",
                            code: error.code,
                            userInfo: [NSLocalizedDescriptionKey: message]
                        )
                    }
                    DebugLogger.shared.warning(
                        "WhisperProvider: Download attempt \(attempt)/\(maxAttempts) failed (\(message)). Retrying...",
                        source: "WhisperProvider"
                    )
                } else {
                    if isLastAttempt { throw error }
                    DebugLogger.shared.warning(
                        "WhisperProvider: Download attempt \(attempt)/\(maxAttempts) failed (\(error.localizedDescription)). Retrying...",
                        source: "WhisperProvider"
                    )
                }

                let delayNanos = UInt64(1_000_000_000) << UInt64(attempt - 1)
                try await Task.sleep(nanoseconds: delayNanos)
            }
        }
    }

    private func downloadFile(from url: URL, to destination: URL, progressHandler: ((Double) -> Void)?) async throws {
        var temporaryURL: URL?
        do {
            let (downloadedURL, response) = try await ProgressiveFileDownloader.download(
                from: url,
                configuration: self.urlSession.configuration
            ) { totalBytesWritten, totalBytesExpectedToWrite in
                guard totalBytesExpectedToWrite > 0 else { return }
                let pct = min(0.999, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
                progressHandler?(pct)
            }
            temporaryURL = downloadedURL
            try Task.checkCancellation()

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(
                    domain: "WhisperProvider",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid server response"]
                )
            }
            guard httpResponse.statusCode == 200 else {
                throw NSError(
                    domain: "WhisperProvider",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to download model (HTTP \(httpResponse.statusCode))"]
                )
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: downloadedURL.path)
            let actualBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard actualBytes > 0 else {
                throw NSError(
                    domain: "WhisperProvider",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Downloaded model is empty. Please try again."]
                )
            }
            if httpResponse.expectedContentLength > 0,
               actualBytes != httpResponse.expectedContentLength
            {
                throw NSError(
                    domain: "WhisperProvider",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Downloaded model size mismatch. Please try again."]
                )
            }

            try Task.checkCancellation()
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: downloadedURL, to: destination)
            temporaryURL = nil
            try Task.checkCancellation()
        } catch {
            if let temporaryURL {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
            let nsError = error as NSError
            if Task.isCancelled
                || error is CancellationError
                || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            {
                throw CancellationError()
            }
            throw error
        }
        try Task.checkCancellation()
        progressHandler?(1.0)
    }
}
