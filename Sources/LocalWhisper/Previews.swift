import AppKit
import SwiftUI

/// `LocalWhisper --render-previews <dir>` writes PNGs of the stats panel and HUD states with fake data.
@MainActor
func renderPreviews(to dir: String) {
    let langs = ["en", "en", "uk", "en", "ru", "en", "uk", "en"]
    var records: [DictationRecord] = []
    for i in 0..<24 {
        let audio = Double.random(in: 2...14)
        records.append(DictationRecord(
            date: Date().addingTimeInterval(Double(i - 24) * 600), audioSeconds: audio,
            transcribeSeconds: audio / Double.random(in: 14...30), words: Int(audio * 2.6),
            language: langs[i % langs.count], text: "Sample dictation number \(i)"
        ))
    }
    let store = StatsStore(previewRecords: records)

    func save<V: View>(_ view: V, _ name: String) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return print("render failed: \(name)") }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        print("wrote \(name)")
    }

    save(StatsPanel(store: store).background(Color(white: 0.16)), "stats-panel.png")
    save(StatsPanel(store: StatsStore(previewRecords: [])).background(Color(white: 0.16)), "stats-panel-empty.png")

    let states: [(RecordingHUD.State, String)] = [
        (.listening(latched: false), "hud-listening.png"),
        (.listening(latched: true), "hud-latched.png"),
        (.transcribing, "hud-transcribing.png"),
        (.rewriting, "hud-rewriting.png"),
        (.message("Didn't catch that", symbol: "ear.trianglebadge.exclamationmark"), "hud-message.png"),
    ]
    for (state, name) in states {
        let model = HUDModel()
        model.state = state
        for i in 0..<HUDModel.barCount {
            model.levels[i] = CGFloat(abs(sin(Double(i) * 0.7)) * 0.8 + 0.1)
        }
        if case .listening(false) = state { model.promptMode = true }
        if state == .rewriting {
            model.committed = "Research the market of local LLMs for Apple Silicon Macs.\n\nGoal: find out which models actually run well on an M3 Max with 48 GB of RAM.\n\nWhat I need:\n- a comparison of Qwen, Llama and Mistral by quality and speed"
        }
        if case .listening(true) = state {
            model.committed = "So the idea is that it types everything live while I"
            model.tentative = " am still talking, word by word"
        }
        save(HUDView(model: model).frame(width: 620, height: 190).background(Color(red: 0.25, green: 0.28, blue: 0.36)), name)
    }
}
