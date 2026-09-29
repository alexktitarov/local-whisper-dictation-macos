import AVFoundation
import Foundation

struct DictationRecord: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let audioSeconds: Double
    let transcribeSeconds: Double
    let words: Int
    let language: String
    let text: String

    var realtimeFactor: Double { transcribeSeconds > 0 ? audioSeconds / transcribeSeconds : 0 }
}

/// Dictation history + live state, shared by the menu panels and the HUD.
@MainActor
final class StatsStore: ObservableObject {
    static let typingWPM = 40.0

    @Published private(set) var records: [DictationRecord] = []
    @Published var modelState = "Loading…"
    @Published var modelReady = false
    @Published var modelName = Settings.modelID
    @Published var micName = StatsStore.currentMicName()

    private let key = "dictationHistory"
    private let maxRecords = 500

    /// In-memory store with canned data, for rendering previews.
    init(previewRecords: [DictationRecord]) {
        records = previewRecords
        modelReady = true
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([DictationRecord].self, from: data) {
            records = saved
        }
    }

    func add(_ record: DictationRecord) {
        records.append(record)
        if records.count > maxRecords { records.removeFirst(records.count - maxRecords) }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func clearHistory() {
        records.removeAll()
        UserDefaults.standard.removeObject(forKey: key)
    }

    func refreshMic() { micName = Self.currentMicName() }

    // MARK: - Derived

    var last: DictationRecord? { records.last }
    var recent: [DictationRecord] { Array(records.suffix(30)) }
    var today: [DictationRecord] { records.filter { Calendar.current.isDateInToday($0.date) } }

    var todayWords: Int { today.reduce(0) { $0 + $1.words } }
    var todaySpeaking: Double { today.reduce(0) { $0 + $1.audioSeconds } }
    var allTimeWords: Int { records.reduce(0) { $0 + $1.words } }

    /// Minutes you'd have spent typing those words, minus the time spent talking.
    var todayMinutesSaved: Double {
        max(0, Double(todayWords) / Self.typingWPM - todaySpeaking / 60)
    }

    var avgLatency: Double {
        let r = recent
        guard !r.isEmpty else { return 0 }
        return r.reduce(0) { $0 + $1.transcribeSeconds } / Double(r.count)
    }

    /// Words per language across all history, largest first.
    var languageBreakdown: [(language: String, words: Int)] {
        var counts: [String: Int] = [:]
        for r in records { counts[r.language, default: 0] += r.words }
        return counts.map { ($0.key, $0.value) }.sorted { $0.words > $1.words }
    }

    var modelSizeOnDisk: String {
        let dir = Settings.modelsFolder.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(modelName)")
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return "—" }
        var total = 0
        for case let url as URL in e {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total > 0 ? ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file) : "—"
    }

    private static func currentMicName() -> String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "No input"
    }
}
