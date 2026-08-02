import Combine
import Foundation

// App-level owner of file-transcription state so switching sidebar pages doesn't kill an in-flight batch; the view re-attaches on return.
@MainActor
final class FileTranscriptionSession {
    static let shared = FileTranscriptionSession()

    private static var sharedIfCreated: FileTranscriptionSession? // lets callers check batch state without force-creating the session

    static var isBatchTranscribing: Bool {
        self.sharedIfCreated?.batchHolder.coordinator?.isRunning == true // both paths drive the same shared ASR model; concurrent inference corrupts output
    }

    /// True from just before a dictation-family recording starts until it ends. Set
    /// synchronously before any `await`, closing the TOCTOU window where the batch's check could pass right before dictation flips this true.
    private(set) var dictationIntent: Bool = false

    let service: MeetingTranscriptionService
    let batchHolder: BatchCoordinatorHolder

    private init() {
        let service = MeetingTranscriptionService(asrService: AppServices.shared.asr)
        self.service = service
        self.batchHolder = BatchCoordinatorHolder(transcribe: { url in
            // At most one of dictation, single-file, and batch transcription may drive the shared ASR model at once.
            while AppServices.shared.asr.isRunning
                || FileTranscriptionSession.shared.dictationIntent
                || service.isTranscribing {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            return try await service.transcribeFile(url)
        })
        Self.sharedIfCreated = self
    }

    func beginDictationIntent() {
        self.dictationIntent = true
    }

    func endDictationIntent() {
        self.dictationIntent = false
    }

    /// releases the flag without force-creating the session, for teardown paths
    static func endDictationIntentIfCreated() {
        self.sharedIfCreated?.endDictationIntent()
    }
}

// Wraps the batch coordinator so a finished batch can be cleared and a fresh one lazily created, republishing its changes.
@MainActor
final class BatchCoordinatorHolder: ObservableObject {
    @Published var coordinator: BatchTranscriptionCoordinator?

    private let transcribe: @MainActor (URL) async throws -> TranscriptionResult
    private var forwarder: AnyCancellable?

    init(transcribe: @escaping @MainActor (URL) async throws -> TranscriptionResult) {
        self.transcribe = transcribe
    }

    func enqueue(_ requests: [BatchTranscriptionCoordinator.Request]) {
        if self.coordinator == nil {
            let coordinator = BatchTranscriptionCoordinator(transcribe: self.transcribe)
            self.forwarder = coordinator.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
            self.coordinator = coordinator
        }
        self.coordinator?.enqueue(requests)
    }

    func clear() {
        self.coordinator?.cancel() // never orphan a running batch: it would transcribe invisibly with no way to reach it
        self.forwarder?.cancel()
        self.forwarder = nil
        self.coordinator = nil
    }
}
