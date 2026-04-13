import Foundation

final class TranscriptionStore {
    static let shared = TranscriptionStore()

    private(set) var entries: [TranscriptionEntry] = []

    private let fileURL: URL? = {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let dir = appSupport.appendingPathComponent("VoiceInput", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("[TranscriptionStore] Could not create directory: %@", error.localizedDescription)
            return nil
        }
        return dir.appendingPathComponent("history.json")
    }()

    private init() {
        load()
    }

    // MARK: - Public API

    func append(_ entry: TranscriptionEntry) {
        entries.insert(entry, at: 0)
        purge()
        save()
    }

    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let url = fileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            entries = []
            return
        }
        do {
            entries = try JSONDecoder().decode([TranscriptionEntry].self, from: data)
            purge()
        } catch {
            NSLog("[TranscriptionStore] Corrupt history.json, resetting: %@", error.localizedDescription)
            entries = []
            save()
        }
    }

    private func save() {
        guard let url = fileURL else { return }
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[TranscriptionStore] Failed to save: %@", error.localizedDescription)
        }
    }

    private func purge() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        entries = entries.filter { $0.date > cutoff }
    }
}
