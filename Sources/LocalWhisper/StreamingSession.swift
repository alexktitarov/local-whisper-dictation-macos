import Foundation

/// Live transcription while the user is still talking.
///
/// Uses the LocalAgreement policy from whisper_streaming: the growing audio buffer is re-transcribed
/// over and over, and a word is *committed* once two consecutive passes agree on it. Committed words
/// never change (safe to type into other apps); the rest is a *tentative* tail shown as a preview.
@MainActor
final class StreamingSession {
    typealias Word = Transcriber.Word

    /// (committed text, tentative text) after every pass.
    var onUpdate: (String, String) -> Void = { _, _ in }
    /// Newly committed text, ready to be typed. Leading space already handled.
    var onCommit: (String) -> Void = { _ in }
    /// Whether committed words go straight into the focused app (decided when the session starts).
    var typesLive = false
    /// Something has already been typed into the target app.
    var hasTyped = false
    /// Stick with the first detected language for the whole dictation.
    var lockLanguage = true

    private let transcriber: Transcriber
    private let samplesSource: () -> [Float]
    private let waitForModel: () async throws -> Void
    private let vocabulary: String
    private let stylePrompt: String
    private var language: String?

    private var committed: [Word] = []
    private var previous: [Word] = []
    private var tentative: [Word] = []
    /// Start of the audio window we re-transcribe; trimmed forward as text gets committed.
    private var bufferStart: Double = 0
    /// How many committed words lie before `bufferStart`. Those feed the prompt; the rest are
    /// still inside the window and will be heard again.
    private var committedBeforeWindow = 0
    /// Punctuation held back from the last committed word. Whisper ends every pass with "." because
    /// it thinks the audio is over; we only type it once the *next* words show whether the sentence
    /// really ended there.
    private var withheld: (index: Int, original: String)?
    private(set) var detectedLanguage: String?
    private var lastLanguage: String?
    var reportedLanguage: String? { detectedLanguage ?? lastLanguage }
    private var loop: Task<Void, Never>?
    private var stopping = false

    private static let sr = AudioRecorder.sampleRate
    private static let minNewAudio = 0.35
    private static let trimAfter = 6.0
    private static let maxBuffer = 20.0
    private static let debug = ProcessInfo.processInfo.environment["LW_DEBUG"] != nil

    init(
        transcriber: Transcriber, language: String?, vocabulary: String,
        waitForModel: @escaping () async throws -> Void, samples: @escaping () -> [Float]
    ) {
        self.transcriber = transcriber
        self.language = Settings.whisperLanguage(for: language)
        self.stylePrompt = Settings.stylePrompt(for: language)
        self.vocabulary = vocabulary
        self.waitForModel = waitForModel
        self.samplesSource = samples
    }

    var committedText: String { Self.join(committed) }

    func start() {
        loop = Task { [weak self] in
            try? await self?.waitForModel()
            var processed = 0
            while let self, !self.stopping, !Task.isCancelled {
                let samples = self.samplesSource()
                let fresh = Double(samples.count - processed) / Self.sr
                if fresh < Self.minNewAudio || samples.count < Int(Self.sr * 0.8) {
                    try? await Task.sleep(for: .milliseconds(80))
                    continue
                }
                processed = samples.count
                await self.pass(samples, final: false)
            }
        }
    }

    /// Stops the live loop, runs one last pass over the full audio and returns the whole text.
    func finish(with samples: [Float]) async -> String {
        stopping = true
        await loop?.value
        try? await waitForModel()
        await pass(samples, final: true)
        return committedText
    }

    func cancel() {
        stopping = true
        loop?.cancel()
    }

    // MARK: - Core

    private func pass(_ samples: [Float], final: Bool) async {
        let startIndex = min(Int(bufferStart * Self.sr), samples.count)
        let window = Array(samples[startIndex...])
        guard Double(window.count) / Self.sr > 0.3, window.peakWindowRMS > 0.008 else {
            if final { finalize(tentative, preceding: nil) }
            return
        }

        // Prompt = style example + vocabulary + what was already typed before this window, so Whisper
        // continues in the same language mix and spelling instead of starting from scratch.
        let history = Self.join(committed.prefix(committedBeforeWindow).suffix(40))
        let context = [stylePrompt, vocabulary, history].filter { !$0.isEmpty }.joined(separator: " ")

        let result: Transcriber.Pass
        do {
            result = try await transcriber.transcribeWords(
                window, offset: bufferStart, language: language ?? detectedLanguage, context: context
            )
        } catch {
            NSLog("LocalWhisper: streaming pass failed: %@", "\(error)")
            if final { finalize(tentative, preceding: nil) }
            return
        }
        // Lock onto the first detected language so the output doesn't flip mid-sentence.
        if language == nil, lockLanguage, detectedLanguage == nil, !result.words.isEmpty { detectedLanguage = result.language }
        if !lockLanguage, !result.words.isEmpty { lastLanguage = result.language }

        // Whisper sometimes "hears" words past the end of the audio, or stretches one word over seconds.
        let windowEnd = Double(samples.count) / Self.sr
        let plausible = result.words.filter { $0.start < windowEnd - 0.05 }
        let hypothesis = dropAlreadyCommitted(plausible)
        var committedRaw = plausible.count - hypothesis.count // hypothesis is always a suffix of plausible
        // This pass's version of the word right before the new text: tells us how it ends now.
        let seam = committedRaw > 0 ? plausible[committedRaw - 1] : nil
        if Self.debug {
            let raw = result.words.map(\.text).joined()
            print(String(format: "  pass buf=%.1f..%.1f final=%d raw=%@", bufferStart, Double(samples.count) / Self.sr, final ? 1 : 0, raw))
        }

        if final {
            finalize(hypothesis, preceding: seam)
        } else {
            var agreed = 0
            while agreed < min(previous.count, hypothesis.count),
                  Self.norm(previous[agreed].text) == Self.norm(hypothesis[agreed].text) {
                agreed += 1
            }
            commit(Array(hypothesis.prefix(agreed)), holdEdge: agreed == hypothesis.count, preceding: seam)
            committedRaw += agreed
            previous = Array(hypothesis.dropFirst(agreed))
            tentative = previous

            // Long run of nothing agreed (e.g. one endless sentence): force out all but the last few words.
            let bufferLength = windowEnd - bufferStart
            if bufferLength > Self.maxBuffer, tentative.count > 6 {
                commit(Array(tentative.dropLast(4)), holdEdge: false, preceding: committedRaw > 0 ? plausible[committedRaw - 1] : nil)
                committedRaw += tentative.count - 4
                tentative = Array(tentative.suffix(4))
                previous = tentative
            }
            trimBuffer(windowEnd: windowEnd, raw: plausible, committedRaw: committedRaw, segmentEnds: result.segmentEnds)
        }
        onUpdate(committedText, Self.join(tentative, continuing: !committed.isEmpty))
    }

    /// - holdEdge: the last word is also the last word Whisper heard, so its punctuation is a guess.
    /// - preceding: this pass's version of the word before `raw`, used to settle withheld punctuation.
    private func commit(_ raw: [Word], holdEdge: Bool, preceding: Word?) {
        guard !raw.isEmpty else { return }
        var words = raw.map(applyVocabulary)
        // Settle the owed punctuation from the same pass as the new words, so "." and the next word's
        // capitalisation always agree.
        var delta = releaseWithheld(preceding: preceding, next: words.first, fallbackToOriginal: false)

        if holdEdge, let last = words.last {
            let (core, punct) = Self.splitTrailingPunctuation(last.text)
            if !punct.isEmpty, !core.trimmingCharacters(in: .whitespaces).isEmpty {
                words[words.count - 1] = Word(text: core, start: last.start, end: last.end)
                withheld = (committed.count + words.count - 1, punct)
            }
        }

        words = fixCase(words, afterSentenceEnd: committed.isEmpty || Self.endsSentence(committedText))
        delta += Self.join(words, continuing: !committed.isEmpty)
        committed.append(contentsOf: words)
        onCommit(delta)
    }

    private func finalize(_ words: [Word], preceding: Word?) {
        commit(words, holdEdge: false, preceding: preceding)
        tentative = []
        // Dictation is over: the last word gets its punctuation back.
        let tail = releaseWithheld(preceding: preceding, next: nil, fallbackToOriginal: true)
        if !tail.isEmpty { onCommit(tail) }
    }

    /// Returns the punctuation to type after the held-back word (possibly none) and records it.
    private func releaseWithheld(preceding: Word?, next: Word?, fallbackToOriginal: Bool) -> String {
        guard let held = withheld else { return "" }
        withheld = nil
        let word = committed[held.index]
        let punct: String
        if let preceding, Self.norm(preceding.text) == Self.norm(word.text) {
            punct = Self.splitTrailingPunctuation(preceding.text).punct
        } else if fallbackToOriginal {
            punct = held.original
        } else if let first = next?.text.trimmingCharacters(in: .whitespaces).first, first.isUppercase,
                  Self.endsSentence(held.original) {
            // Can't see the seam, but the next word starts a sentence: keep the full stop.
            punct = held.original
        } else {
            punct = ""
        }
        if !punct.isEmpty {
            committed[held.index] = Word(text: word.text + punct, start: word.start, end: word.end)
        }
        return punct
    }

    /// Removes the part of a pass that repeats already-committed text.
    ///
    /// After a buffer trim the window deliberately re-covers the last couple of seconds of committed
    /// speech, so we look for the last committed words inside the new pass and keep only what follows.
    /// Matching text is far more reliable than timestamps (which drift when a prompt is used).
    private func dropAlreadyCommitted(_ words: [Word]) -> [Word] {
        guard !committed.isEmpty, !words.isEmpty else { return words }
        let hyp = words.map { Self.norm($0.text) }
        // Where the committed text should end inside this window.
        let expected = committed.count - committedBeforeWindow

        for anchor in stride(from: min(4, committed.count), through: 2, by: -1) {
            let tail = committed.suffix(anchor).map { Self.norm($0.text) }
            guard hyp.count >= anchor else { continue }
            let matches = (0...(hyp.count - anchor)).filter { Array(hyp[$0..<$0 + anchor]) == tail }
            if let j = matches.min(by: { abs($0 + anchor - expected) < abs($1 + anchor - expected) }) {
                return Array(words[(j + anchor)...])
            }
        }

        // No textual anchor (e.g. Whisper reworded the seam): fall back to timestamps + 1-word overlap.
        let lastEnd = committed.last!.end
        var fresh = words.filter { $0.start > lastEnd - 0.1 }
        if let first = fresh.first, Self.norm(first.text) == Self.norm(committed.last!.text) {
            fresh.removeFirst()
        }
        return fresh
    }

    /// Keep the re-transcribed window short so each pass stays fast. We cut at the end of the latest
    /// segment whose words are all committed: segment boundaries come from Whisper's timestamp tokens
    /// and sit on pauses / sentence ends, so nothing gets chopped.
    private func trimBuffer(windowEnd: Double, raw: [Word], committedRaw: Int, segmentEnds: [Double]) {
        let length = windowEnd - bufferStart
        guard length > Self.trimAfter, committedRaw > 0, committedRaw <= raw.count else { return }

        var segment = raw[committedRaw - 1].segment
        if committedRaw < raw.count, raw[committedRaw].segment == segment { segment -= 1 }

        let cut: Double
        let stillInWindow: Int
        // Only a segment followed by another one marks a real break; the last segment's end is just
        // wherever the audio currently stops.
        if segment >= 0, segment < segmentEnds.count - 1, segmentEnds[segment] > bufferStart + 1 {
            cut = segmentEnds[segment]
            stillInWindow = raw[..<committedRaw].filter { $0.segment > segment }.count
        } else if length > Self.maxBuffer {
            // One giant segment: cut a second before the last committed word; the text anchor dedupes.
            cut = max(bufferStart, raw[committedRaw - 1].start - 1)
            stillInWindow = raw[..<committedRaw].filter { $0.end > cut }.count
        } else {
            return
        }
        bufferStart = cut
        committedBeforeWindow = max(0, committed.count - stillInWindow)
    }

    // MARK: - Text helpers

    /// Belt and braces on top of the prompt: force the exact spelling/casing of vocabulary words,
    /// "whisperkit," → "WhisperKit,".
    private lazy var vocabularyTerms: [String: String] = {
        var map: [String: String] = [:]
        for term in vocabulary.split(separator: ",") {
            let t = term.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !t.contains(" ") { map[Self.norm(t)] = t }
        }
        return map
    }()

    private func applyVocabulary(_ word: Word) -> Word {
        guard !vocabularyTerms.isEmpty else { return word }
        let core = word.text.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        guard !core.isEmpty, let replacement = vocabularyTerms[Self.norm(core)], replacement != core,
              let range = word.text.range(of: core) else { return word }
        return Word(text: word.text.replacingCharacters(in: range, with: replacement), start: word.start, end: word.end)
    }

    static func join<S: Sequence>(_ words: S, continuing: Bool = false) -> String where S.Element == Word {
        // Whisper words carry their own leading space (" hello", but "n't" / "," attach directly).
        var text = words.map(\.text).joined()
        while text.last?.isWhitespace == true { text.removeLast() }
        if !continuing { text = text.trimmingCharacters(in: .whitespaces) }
        return text
    }

    private static let trailingPunctuation = Set(".,!?…;:")

    private static func endsSentence(_ text: String) -> Bool {
        text.last.map { ".!?…".contains($0) } ?? true
    }

    /// Passes that start mid-sentence (after a buffer trim) often come back lowercase, and vice versa.
    /// Capitalise after a sentence end and fix English "i" / "i'm".
    private func fixCase(_ words: [Word], afterSentenceEnd: Bool) -> [Word] {
        var out: [Word] = []
        var sentenceStart = afterSentenceEnd
        for word in words {
            var text = word.text
            let core = text.trimmingCharacters(in: .whitespaces)
            let lowerCore = core.lowercased()
            if lowerCore == "i" || lowerCore.hasPrefix("i'") || lowerCore.hasPrefix("i’") {
                text = text.replacingOccurrences(of: "i", with: "I", options: .anchored,
                                                 range: text.range(of: core))
            } else if sentenceStart, let first = core.first, first.isLowercase, let r = text.range(of: String(first)) {
                text.replaceSubrange(r, with: String(first).uppercased())
            }
            out.append(Word(text: text, start: word.start, end: word.end))
            sentenceStart = Self.endsSentence(core)
        }
        return out
    }

    static func splitTrailingPunctuation(_ text: String) -> (core: String, punct: String) {
        var core = text
        var punct = ""
        while let last = core.last, trailingPunctuation.contains(last) {
            punct.insert(core.removeLast(), at: punct.startIndex)
        }
        return (core, punct)
    }

    private static func norm(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
