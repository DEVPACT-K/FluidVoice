import Combine
import SwiftUI
import UniformTypeIdentifiers

struct MeetingTranscriptionView: View {
    let asrService: ASRService
    // Owned by FileTranscriptionSession so in-flight transcriptions survive sidebar navigation.
    @ObservedObject private var transcriptionService: MeetingTranscriptionService
    @ObservedObject private var batchHolder: BatchCoordinatorHolder
    @ObservedObject private var fileHistoryStore = FileTranscriptionHistoryStore.shared
    @State private var selectedFileURL: URL?
    @Environment(\.theme) private var theme

    init(asrService: ASRService) {
        self.asrService = asrService
        let session = FileTranscriptionSession.shared
        self.transcriptionService = session.service
        self.batchHolder = session.batchHolder
    }

    @State private var showingFilePicker = false
    @State private var showingExportDialog = false
    @State private var exportResult: TranscriptionResult?
    @State private var exportFormat: ExportFormat = .text
    @State private var showingCopyConfirmation = false
    @State private var isDropTargeted = false
    @State private var dropErrorMessage: String?
    @State private var dropErrorGeneration = 0

    enum ExportFormat: String, CaseIterable {
        case text = "Text (.txt)"
        case json = "JSON (.json)"

        var fileExtension: String {
            switch self {
            case .text: return "txt"
            case .json: return "json"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.fluidGreen.gradient)

                Text("Meeting Transcription")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Choose an audio or video file to transcribe")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 40)
            .padding(.bottom, 30)

            // Main Content Area
            ScrollView {
                VStack(spacing: 24) {
                    // File Selection Card
                    self.fileSelectionCard

                    // Progress Card (only show when transcribing outside a batch)
                    if self.transcriptionService.isTranscribing && !self.isBatchActive {
                        self.progressCard
                    }

                    // Results Card (only show when we have results outside a batch)
                    if let result = transcriptionService.result, !self.isBatchActive {
                        self.resultsCard(result: result)
                    }

                    // Error Card (only show when we have a single-file error)
                    if let error = transcriptionService.error, !self.isBatchActive {
                        self.errorCard(error: error)
                    }

                    // Drop error (unsupported file type)
                    if let message = self.dropErrorMessage {
                        self.dropErrorCard(message: message)
                    }

                    // Batch transcription progress/results
                    if self.isBatchActive {
                        self.batchSection
                    }

                    // Recent transcriptions (persisted history)
                    if !self.fileHistoryStore.entries.isEmpty {
                        Divider()
                            .padding(.vertical, 8)
                        self.recentTranscriptionsSection
                    }
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Overlay (not background): AppKit's front-to-back drag search needs this above
        // the SwiftUI content; hitTest returns nil so clicks pass through.
        .overlay(
            PromiseAwareDropView(
                onTargetedChange: { self.isDropTargeted = $0 },
                onFiles: { self.handleIncomingFiles($0) },
                onError: { self.showDropError($0) }
            )
        )
        .background(self.theme.palette.windowBackground)
        .overlay(alignment: .topTrailing) {
            if self.showingCopyConfirmation {
                Text("Copied!")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.fluidGreen.opacity(0.9))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .padding()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .fileExporter(
            isPresented: self.$showingExportDialog,
            document: TranscriptionDocument(
                result: self.exportResult ?? TranscriptionResult(text: "", confidence: 0, duration: 0, processingTime: 0, fileName: "transcript"),
                format: self.exportFormat,
                service: self.transcriptionService
            ),
            contentType: self.exportFormat == .text ? .plainText : .json,
            defaultFilename: "\((self.exportResult?.fileName).map { "\($0)_transcript" } ?? "transcript").\(self.exportFormat.fileExtension)"
        ) { exportCompletion in
            switch exportCompletion {
            case .success:
                DebugLogger.shared.info("File exported successfully", source: "MeetingTranscriptionView")
            case let .failure(error):
                DebugLogger.shared.error("Export failed: \(error)", source: "MeetingTranscriptionView")
            }
            self.exportResult = nil
        }
    }

    // MARK: - File Selection Card

    private var fileSelectionCard: some View {
        VStack(spacing: 16) {
            if let fileURL = selectedFileURL {
                // Show selected file
                HStack {
                    Image(systemName: "doc.fill")
                        .font(.title2)
                        .foregroundColor(Color.fluidGreen)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(fileURL.lastPathComponent)
                            .font(.headline)

                        Text(self.formatFileSize(fileURL: fileURL))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button(action: {
                        self.selectedFileURL = nil
                        self.transcriptionService.reset()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(self.theme.palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(self.theme.palette.cardBorder.opacity(0.5), lineWidth: 1)
                        )
                )

                // Transcribe Button
                Button(action: {
                    Task {
                        await self.transcribeFile()
                    }
                }) {
                    HStack {
                        Image(systemName: "waveform")
                        Text("Transcribe")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(self.transcriptionService.isTranscribing || self.isBatchActive)

            } else {
                // File picker button – whole area is tappable; supports drag-and-drop
                Button(action: {
                    self.showingFilePicker = true
                }) {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.up.doc.fill")
                            .font(.system(size: 32))

                        Text("Drag and drop a file here, or click to open")
                            .font(.headline)

                        Text(MeetingTranscriptionService.supportedFormatsDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(self.theme.palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .foregroundColor(Color.fluidGreen.opacity(self.isDropTargeted ? 0.7 : 0.3))
                )
            }
        }
        .fileImporter(
            isPresented: self.$showingFilePicker,
            allowedContentTypes: MeetingTranscriptionService.allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                self.handleIncomingFiles(urls.map { (url: $0, stagingDir: nil) })
            case let .failure(error):
                DebugLogger.shared.error("File picker error: \(error)", source: "MeetingTranscriptionView")
            }
        }
    }

    // MARK: - Progress Card

    private var progressCard: some View {
        VStack(spacing: 16) {
            ProgressView(value: self.transcriptionService.progress)
                .progressViewStyle(.linear)

            HStack {
                ProgressView()
                    .controlSize(.small)
                    .fixedSize()

                Text(self.transcriptionService.currentStatus)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(self.theme.palette.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                )
        )
    }

    // MARK: - Results Card

    private func resultsCard(result: TranscriptionResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with stats
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transcription Complete")
                        .font(.headline)

                    HStack(spacing: 16) {
                        Label("\(String(format: "%.1f", result.duration))s", systemImage: "clock")
                        Label("\(String(format: "%.0f%%", result.confidence * 100))", systemImage: "checkmark.circle")
                        Label(
                            "\(String(format: "%.1f", result.duration / result.processingTime))x",
                            systemImage: "speedometer"
                        )
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Spacer()

                // Action buttons
                HStack(spacing: 8) {
                    Button(action: {
                        self.copyToClipboard(result.text)
                    }) {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy to clipboard")

                    Button(action: {
                        self.exportResult = result
                        self.showingExportDialog = true
                    }) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help("Export transcription")
                }
                .buttonStyle(.borderless)
            }

            Divider()

            // Transcription text
            ScrollView {
                Text(result.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(maxHeight: 300)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(self.theme.palette.contentBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                    )
            )
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(self.theme.palette.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                )
        )
    }

    // MARK: - Recent Transcriptions Section

    private var recentTranscriptionsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Recent transcriptions")
                    .font(.headline)
                Spacer()
                if !self.fileHistoryStore.entries.isEmpty {
                    Button("Clear all") {
                        self.fileHistoryStore.clearAll()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .font(.caption)
                }
            }

            VStack(spacing: 8) {
                ForEach(self.fileHistoryStore.entries) { entry in
                    self.recentEntryRow(entry: entry)
                }
            }

            if let entry = self.fileHistoryStore.selectedEntry {
                self.historyDetailCard(entry: entry)
            }
        }
    }

    private func recentEntryRow(entry: FileTranscriptionEntry) -> some View {
        let isSelected = self.fileHistoryStore.selectedEntryID == entry.id
        return Button(action: {
            self.fileHistoryStore.selectedEntryID = entry.id
        }) {
            HStack {
                Image(systemName: "doc.text.fill")
                    .font(.body)
                    .foregroundColor(Color.fluidGreen)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.fileName)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    Text(entry.relativeTimeString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(entry.previewText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "chevron.right.circle.fill")
                        .foregroundColor(Color.fluidGreen)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(self.theme.palette.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isSelected ? Color.fluidGreen.opacity(0.5) : self.theme.palette.cardBorder.opacity(0.3), lineWidth: isSelected ? 2 : 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func historyDetailCard(entry: FileTranscriptionEntry) -> some View {
        let result = entry.toTranscriptionResult()
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("From history")
                        .font(.headline)
                    HStack(spacing: 16) {
                        Label("\(String(format: "%.1f", entry.duration))s", systemImage: "clock")
                        Label("\(String(format: "%.0f%%", entry.confidence * 100))", systemImage: "checkmark.circle")
                        Label(entry.fullDateString, systemImage: "calendar")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button(action: { self.copyToClipboard(entry.text) }) {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy to clipboard")
                    Button(action: {
                        self.exportResult = result
                        self.showingExportDialog = true
                    }) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help("Export transcription")
                    Button(action: {
                        self.fileHistoryStore.deleteEntry(id: entry.id)
                    }) {
                        Image(systemName: "trash")
                    }
                    .help("Remove from history")
                }
                .buttonStyle(.borderless)
            }
            Divider()
            ScrollView {
                Text(entry.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(maxHeight: 300)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(self.theme.palette.contentBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                    )
            )
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(self.theme.palette.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                )
        )
    }

    // MARK: - Error Card

    private func errorCard(error: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)

            Text(error)
                .font(.subheadline)

            Spacer()

            Button("Dismiss") {
                self.transcriptionService.reset()
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.red.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.red.opacity(0.4), lineWidth: 1)
                )
        )
    }

    // MARK: - Drop Error Card

    private func dropErrorCard(message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)

            Text(message)
                .font(.subheadline)

            Spacer()

            Button("Dismiss") {
                self.dropErrorMessage = nil
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.red.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.red.opacity(0.4), lineWidth: 1)
                )
        )
    }

    // MARK: - Batch Transcription Section

    @ViewBuilder
    private var batchSection: some View {
        if let coordinator = self.batchHolder.coordinator, !coordinator.items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(self.batchHeader(coordinator: coordinator))
                        .font(.headline)

                    Spacer()

                    if coordinator.isRunning {
                        // In-flight file may still run to completion (no interruption point),
                        // hence "Cancelling" rather than an instant stop.
                        if coordinator.isCancelRequested {
                            Text("Cancelling…")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Button("Cancel") { coordinator.cancel() }
                                .buttonStyle(.borderless)
                                .foregroundColor(.red)
                        }
                    } else {
                        Button("Done") { self.dismissBatch() }
                            .buttonStyle(.borderless)
                    }
                }

                Divider()

                VStack(spacing: 8) {
                    ForEach(coordinator.items) { item in
                        self.batchRow(item: item)
                    }
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(self.theme.palette.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                    )
            )
        }
    }

    private func batchHeader(coordinator: BatchTranscriptionCoordinator) -> String {
        if coordinator.isRunning {
            return "Transcribing \(self.currentBatchPosition(in: coordinator)) of \(coordinator.items.count)"
        }
        return "Batch complete — \(coordinator.completedCount) transcribed, \(coordinator.failedCount) failed"
    }

    /// One-based position of the item currently being transcribed (or the next pending
    /// item while between files), for the "Transcribing x of y" header.
    private func currentBatchPosition(in coordinator: BatchTranscriptionCoordinator) -> Int {
        let items = coordinator.items
        if let index = items.firstIndex(where: { if case .transcribing = $0.status { return true }; return false }) {
            return index + 1
        }
        if let index = items.firstIndex(where: { if case .pending = $0.status { return true }; return false }) {
            return index + 1
        }
        return items.count
    }

    private func batchRow(item: BatchTranscriptionCoordinator.Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                self.batchDetailText(for: item.status)
            }

            Spacer()

            self.batchStatusIcon(for: item.status)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(self.theme.palette.contentBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(self.theme.palette.cardBorder.opacity(0.3), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func batchDetailText(for status: BatchTranscriptionCoordinator.Status) -> some View {
        switch status {
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundColor(.red)
                .lineLimit(2)
                .truncationMode(.tail)
        case .noSpeech:
            Text("No speech detected")
                .font(.caption)
                .foregroundColor(.secondary)
        case .cancelled:
            Text("Cancelled")
                .font(.caption)
                .foregroundColor(.secondary)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func batchStatusIcon(for status: BatchTranscriptionCoordinator.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .foregroundColor(.secondary)
                .opacity(0.5)
        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .fixedSize()
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(Color.fluidGreen)
        case .noSpeech:
            Image(systemName: "speaker.slash.fill")
                .foregroundColor(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        case .cancelled:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Helper Functions

    /// True while a batch coordinator has any enqueued items (running or finished-but-
    /// not-dismissed); suppresses single-file cards since `transcribeFile` mutates the
    /// shared service state per batch item.
    private var isBatchActive: Bool {
        guard let coordinator = self.batchHolder.coordinator else { return false }
        return !coordinator.items.isEmpty
    }

    /// Routes incoming files from a drop or the file picker. A single concrete file (no
    /// staging dir) follows the existing single-file flow; everything else — multiple
    /// files, or any staged/promised file — is enqueued on the batch coordinator so
    /// staged dirs are reliably cleaned up after transcription.
    private func handleIncomingFiles(_ files: [(url: URL, stagingDir: URL?)]) {
        guard !files.isEmpty else { return }
        self.dropErrorMessage = nil

        if files.count == 1, let file = files.first, file.stagingDir == nil,
           !self.isBatchActive, !self.transcriptionService.isTranscribing {
            self.selectedFileURL = file.url
            self.transcriptionService.reset()
            return
        }

        self.batchHolder.enqueue(files.map { .init(url: $0.url, stagingDir: $0.stagingDir) })
    }

    /// Auto-dismisses after a few seconds: promise resolution can report errors up to
    /// two minutes after the drop, so without this a stale red card could sit over an
    /// already-successful batch until manually closed.
    private func showDropError(_ message: String) {
        self.dropErrorMessage = message
        self.dropErrorGeneration += 1
        let generation = self.dropErrorGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if self.dropErrorGeneration == generation {
                self.dropErrorMessage = nil
            }
        }
    }

    /// Resets shared service state so a subsequent batch starts fresh with no stale
    /// single-file result.

    private func dismissBatch() {
        self.batchHolder.clear()
        self.transcriptionService.reset()
    }

    private func transcribeFile() async {
        guard let fileURL = selectedFileURL else { return }

        do {
            _ = try await self.transcriptionService.transcribeFile(fileURL)
        } catch {
            DebugLogger.shared.error("Transcription error: \(error)", source: "MeetingTranscriptionView")
        }
    }

    private func formatFileSize(fileURL: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? Int64
        else {
            return "Unknown size"
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        withAnimation {
            self.showingCopyConfirmation = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                self.showingCopyConfirmation = false
            }
        }
    }
}

// MARK: - Batch Coordinator Ownership

// MARK: - Document for Export

struct TranscriptionDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.plainText, .json]
    }

    let result: TranscriptionResult
    let format: MeetingTranscriptionView.ExportFormat
    let service: MeetingTranscriptionService

    init(
        result: TranscriptionResult,
        format: MeetingTranscriptionView.ExportFormat,
        service: MeetingTranscriptionService
    ) {
        self.result = result
        self.format = format
        self.service = service
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnknown)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("temp.\(self.format.fileExtension)")

        switch self.format {
        case .text:
            try self.service.exportToText(self.result, to: tempURL)
        case .json:
            try self.service.exportToJSON(self.result, to: tempURL)
        }

        let data = try Data(contentsOf: tempURL)
        try? FileManager.default.removeItem(at: tempURL)

        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Preview

#Preview {
    MeetingTranscriptionView(asrService: ASRService())
        .frame(width: 700, height: 800)
}
