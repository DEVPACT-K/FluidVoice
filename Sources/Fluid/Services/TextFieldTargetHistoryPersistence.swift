import Foundation

nonisolated struct PersistedTextFieldTargetHistory: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion = Self.currentSchemaVersion
    var apps: [PersistedTextFieldTargetApp] = []
}

nonisolated struct PersistedTextFieldTargetApp: Codable, Equatable {
    var applicationIdentifier: String
    var fields: [PersistedTextFieldTarget] = []
}

nonisolated struct PersistedTextFieldTarget: Codable, Equatable {
    var windowFingerprint: TextFieldWindowFingerprint?
    var fingerprint: TextFieldFingerprint
    var lastUsedAt: TimeInterval
    var useCount: Int
}

protocol TextFieldTargetHistoryPersistence: AnyObject {
    func load(completion: @escaping (PersistedTextFieldTargetHistory?) -> Void)
    func save(_ history: PersistedTextFieldTargetHistory)
    func clear()
    func flush()
}

/// Stores the small, bounded fingerprint history in Application Support. Encoding and file I/O
/// stay on a utility queue so insertion and recording-start paths never wait on disk work.
final class FileTextFieldHistoryStore: TextFieldTargetHistoryPersistence {
    static let fileName = "RememberedTextFields.v1.json"

    private let fileURL: URL?
    private let queue = DispatchQueue(
        label: "com.fluidvoice.remembered-text-fields.persistence",
        qos: .utility
    )

    init(fileURL: URL? = FileTextFieldHistoryStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func load(completion: @escaping (PersistedTextFieldTargetHistory?) -> Void) {
        self.queue.async { [fileURL] in
            guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
                completion(nil)
                return
            }
            guard let history = try? JSONDecoder().decode(PersistedTextFieldTargetHistory.self, from: data),
                  history.schemaVersion == PersistedTextFieldTargetHistory.currentSchemaVersion
            else {
                try? FileManager.default.removeItem(at: fileURL)
                completion(nil)
                return
            }
            completion(history)
        }
    }

    func save(_ history: PersistedTextFieldTargetHistory) {
        self.queue.async { [fileURL] in
            guard let fileURL else { return }
            guard let data = try? JSONEncoder().encode(history) else { return }
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: fileURL, options: .atomic)
            } catch {
                // The in-memory history remains authoritative for this session.
            }
        }
    }

    func clear() {
        self.queue.async { [fileURL] in
            guard let fileURL else { return }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func flush() {
        self.queue.sync {}
    }

    private static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FluidVoice", isDirectory: true)
            .appendingPathComponent(self.fileName, isDirectory: false)
    }
}
