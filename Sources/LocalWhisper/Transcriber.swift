import CoreML
import Foundation
import WhisperKit

/// Forbids "end of text" / blank as the very first generated token, like OpenAI's `suppress_blank`.
/// WhisperKit's own SuppressBlankFilter checks the wrong index once a prompt is prepended, so with a
/// prompt on short audio the model would otherwise answer with an empty transcript.
final class SuppressEmptyStartFilter: LogitsFiltering {
    private let special: SpecialTokens
    private let suppressed: [Int]

    init(specialTokens: SpecialTokens) {
        special = specialTokens
        suppressed = [specialTokens.endToken, specialTokens.whitespaceToken]
    }

    /// The first sampled position follows the prefill: `… <|transcribe|> <|notimestamps|>` or `… <|transcribe|> <|0.00|>`.
    private func isFirstSample(_ tokens: [Int]) -> Bool {
        guard let last = tokens.last else { return false }
        if last == special.noTimestampsToken { return true }
        guard last == special.timeTokenBegin, tokens.count >= 2 else { return false }
        let task = tokens[tokens.count - 2]
        return task == special.transcribeToken || task == special.translateToken
    }

    func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
        guard isFirstSample(tokens) else { return logits }
        for token in suppressed {
            logits[[0, 0, token as NSNumber]] = NSNumber(value: -Float.infinity)
        }
        return logits
    }
}

/// Owns the WhisperKit pipeline. Load once, keep warm, transcribe many times.
actor Transcriber {
    private var pipe: WhisperKit?
    private(set) var loadedModel: String?

    func load(model: String, progress: @escaping @Sendable (String) -> Void) async throws {
        if loadedModel == model, pipe != nil { return }
        pipe = nil
        loadedModel = nil

        progress("Loading \(model)… (first time downloads + compiles, can take a minute)")
        let config = WhisperKitConfig(
            model: model,
            downloadBase: Settings.modelsFolder,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )
        pipe = try await WhisperKit(config)
        loadedModel = model
        progress("Ready")
    }

    struct Output: Sendable {
        let text: String
        let language: String
    }

    func transcribe(_ samples: [Float], language: String?, vocabulary: String) async throws -> Output {
        guard let pipe else { throw TranscriberError.notLoaded }

        let languageCode = language
        let language = Settings.whisperLanguage(for: languageCode)
        var options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperatureFallbackCount: 3,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: .vad
        )

        let vocab = [Settings.stylePrompt(for: languageCode), vocabulary]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !vocab.isEmpty, let tokenizer = pipe.tokenizer {
            options.promptTokens = tokenizer.encode(text: " " + vocab)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }

        pipe.textDecoder.logitsFilters = Self.filters(for: options, tokenizer: pipe.tokenizer)
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
        let detected = results.first?.language ?? language ?? "?"
        return Output(text: Self.clean(text), language: detected)
    }

    struct Word: Sendable {
        /// Includes Whisper's leading space, e.g. " hello".
        let text: String
        /// Absolute seconds since the recording started (interpolated inside the segment).
        let start: Double
        let end: Double
        /// Index into `Pass.segmentEnds`; -1 for words we built ourselves.
        var segment: Int = -1
    }

    struct Pass: Sendable {
        let words: [Word]
        /// Absolute end time of each segment. These come from Whisper's timestamp tokens, which stay
        /// accurate with a prompt (unlike cross-attention word timings), so they're safe cut points.
        let segmentEnds: [Double]
        let language: String
    }

    /// One streaming pass over `samples` (which begin `offset` seconds into the recording).
    /// `context` is fed as the prompt: style example, vocabulary and text already typed before the window.
    func transcribeWords(
        _ samples: [Float], offset: Double, language: String?, context: String
    ) async throws -> Pass {
        guard let pipe else { throw TranscriberError.notLoaded }

        var options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperatureFallbackCount: 1,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            logProbThreshold: nil,
            firstTokenLogProbThreshold: nil
        )
        let prompt = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty, let tokenizer = pipe.tokenizer {
            let tokens = tokenizer.encode(text: " " + prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            options.promptTokens = Array(tokens.suffix(Constants.maxTokenContext / 2 - 1))
        }

        pipe.textDecoder.logitsFilters = Self.filters(for: options, tokenizer: pipe.tokenizer)
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        let detected = results.first?.language ?? language ?? "?"

        var words: [Word] = []
        var ends: [Double] = []
        for result in results {
            for segment in result.segments {
                let parts = Self.clean(segment.text).split(separator: " ").map { " " + $0 }
                let start = offset + Double(segment.start)
                let end = offset + Double(segment.end)
                guard !parts.isEmpty, end > start else { continue }
                let step = (end - start) / Double(parts.count)
                for (i, part) in parts.enumerated() where !Self.isNoise(part) {
                    let s = start + step * Double(i)
                    words.append(Word(text: part, start: s, end: s + step, segment: ends.count))
                }
                ends.append(end)
            }
        }
        if ProcessInfo.processInfo.environment["LW_DEBUG"] != nil {
            for r in results {
                for seg in r.segments {
                    print(String(format: "    seg %.1f-%.1f %@", offset + Double(seg.start), offset + Double(seg.end), seg.text))
                }
            }
        }
        return Pass(words: words, segmentEnds: ends, language: detected)
    }

    private static func filters(for options: DecodingOptions, tokenizer: WhisperTokenizer?) -> [any LogitsFiltering]? {
        guard options.promptTokens != nil, let tokenizer else { return nil }
        return [SuppressEmptyStartFilter(specialTokens: tokenizer.specialTokens)]
    }

    private static func isNoise(_ word: String) -> Bool {
        let w = word.trimmingCharacters(in: .whitespaces)
        return w.isEmpty || w.hasPrefix("[") || w.hasPrefix("(") || w.hasPrefix("<|")
    }

    /// Drops Whisper's classic silence hallucinations and bracketed noise tags.
    static func clean(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if LanguageData.silenceHallucinations.contains(text.lowercased()) { return "" }
        return text
    }

    enum TranscriberError: LocalizedError {
        case notLoaded
        var errorDescription: String? { "Model is not loaded yet." }
    }
}
