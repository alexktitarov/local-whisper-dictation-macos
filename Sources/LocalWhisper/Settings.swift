import Foundation

struct ModelOption {
    let id: String
    let title: String
    let shortTitle: String
}

enum Settings {
    static let models: [ModelOption] = [
        ModelOption(id: "openai_whisper-large-v3-v20240930_turbo_632MB", title: "Large v3 Turbo (best, ~630 MB)", shortTitle: "Large v3 Turbo"),
        ModelOption(id: "openai_whisper-small", title: "Small (faster, ~240 MB)", shortTitle: "Small"),
        ModelOption(id: "openai_whisper-base", title: "Base (fastest, ~75 MB)", shortTitle: "Base"),
    ]

    /// nil code = auto-detect
    static let languages: [(code: String?, title: String)] = [
        (nil, "Auto-detect"),
        ("ru+en", "Russian + English (mixed)"),
        ("uk+en", "Ukrainian + English (mixed)"),
        ("en", "English"),
        ("uk", "Ukrainian"),
        ("ru", "Russian"),
        ("de", "German"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("pl", "Polish"),
    ]

    /// "ru+en" → "ru": the mixed modes decode as the base language, the prompt keeps English words intact.
    static func whisperLanguage(for code: String?) -> String? {
        code?.components(separatedBy: "+").first
    }

    /// Code-switched example fed to Whisper as a prompt in the mixed-language modes (see `LanguageData`).
    static func stylePrompt(for code: String?) -> String {
        code.flatMap { LanguageData.codeSwitchingPrompts[$0] } ?? ""
    }

    private static let defaults = UserDefaults.standard

    static var modelID: String {
        get { defaults.string(forKey: "modelID") ?? models[0].id }
        set { defaults.set(newValue, forKey: "modelID") }
    }

    static var language: String? {
        get { defaults.string(forKey: "language") }
        set { defaults.set(newValue, forKey: "language") }
    }

    static var playSounds: Bool {
        get { defaults.object(forKey: "playSounds") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "playSounds") }
    }

    /// Type committed words into the focused app while still talking (vs. paste everything on release).
    static var liveTyping: Bool {
        get { defaults.object(forKey: "liveTyping") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "liveTyping") }
    }

    /// Groq model used to rewrite dictation in prompt mode; nil = pick the first Qwen model available.
    static var promptModel: String? {
        get { defaults.string(forKey: "promptModel") }
        set { defaults.set(newValue, forKey: "promptModel") }
    }

    /// Words/names Whisper should spell correctly, fed as the decoder prompt.
    static var vocabulary: String {
        get { defaults.string(forKey: "vocabulary") ?? "" }
        set { defaults.set(newValue, forKey: "vocabulary") }
    }

    static var modelsFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("LocalWhisper/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
