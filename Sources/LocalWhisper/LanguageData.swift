import Foundation

/// Model-input data for non-English speech.
///
/// Everything user-facing in this project is English. The strings below are the exception because
/// they are *fed to or matched against Whisper*, and only work in the language they target.
enum LanguageData {
    /// Decoder prompts for the mixed-language modes. Whisper imitates the style of its prompt, so a
    /// short code-switched example (whole English clauses, not just English nouns) stops it from
    /// dropping or transliterating the English parts of Russian/Ukrainian speech.
    static let codeSwitchingPrompts: [String: String] = [
        "ru+en": "Так, смотри. I think we should ship it today, но сначала надо пофиксить этот bug в API. Окей, let's do it.",
        "uk+en": "Так, дивись. I think we should ship it today, але спочатку треба пофіксити цей bug в API. Окей, let's do it.",
    ]

    /// Phrases Whisper tends to invent on silence or noise (learned from video subtitles).
    /// A transcript consisting only of one of these is discarded.
    static let silenceHallucinations: Set<String> = [
        "thank you.", "thanks for watching!", "thank you for watching.", "thanks for watching.", "you", "bye.",
        "продолжение следует...", "субтитры сделал dimatorzok", // Russian
        "дякую за перегляд!", // Ukrainian
    ]
}
