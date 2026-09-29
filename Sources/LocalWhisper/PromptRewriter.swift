import Foundation

/// Turns a dictated task ("research X for me") into a thorough prompt for ChatGPT / Claude,
/// using an LLM on Groq (OpenAI-compatible API).
enum PromptRewriter {
    static let keychainAccount = "groq-api-key"
    private static let base = URL(string: "https://api.groq.com/openai/v1/")!

    static var apiKey: String? {
        guard let key = Keychain.read(keychainAccount), !key.isEmpty else { return nil }
        return key
    }

    enum RewriteError: LocalizedError {
        case noKey
        case http(Int, String)
        case empty

        var errorDescription: String? {
            switch self {
            case .noKey: "No Groq API key — set it in Prompt Mode › Groq API Key…"
            case .http(429, _): "Groq per-minute limit hit — pasted as dictated, try again in a minute"
            case .http(let code, let body): "Groq error \(code): \(PromptRewriter.message(from: body))"
            case .empty: "The model returned nothing"
            }
        }
    }

    /// Pulls `error.message` out of an OpenAI-style error body.
    static func message(from body: String) -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else { return String(body.prefix(300)) }
        return message
    }

    static let systemPrompt = """
    You turn a dictated, often messy request into a high-quality prompt that the user will send to an \
    AI assistant (ChatGPT or Claude). You are NOT the assistant: never perform the task, never answer it, \
    never add commentary. Output only the finished prompt text.

    Rules:
    - Write in the same language the user spoke (mixed Russian/English stays mixed; keep technical terms as said).
    - Keep every concrete detail the user gave: names, numbers, constraints, preferences. Never invent facts, \
    sources, deadlines or requirements the user did not imply.
    - Fix speech-recognition noise and filler words; make it clear and specific.
    - Scale to the task: a small request becomes a few precise sentences; a research or analysis task gets structure.
    - For substantial tasks use short labelled sections, only the ones that add value:
      Goal · Context · What I need (deliverables) · Scope & constraints · Approach / what to cover · \
    Output format · What "good" looks like.
    - Research tasks: specify depth, angles to compare, that claims should be backed by sources, and end with a \
    concise conclusion or recommendation.
    - If important information is missing and the answer depends on it, add a final line asking the assistant \
    to ask clarifying questions first (phrase it in the user's language).
    - Address the assistant directly, in the imperative. Plain text with simple dashes for lists; no \
    preamble like "Here is your prompt".
    """

    /// Streams the rewritten prompt. `onDelta` receives text chunks as they arrive (on the main actor).
    static func rewrite(
        _ dictation: String, model: String, onDelta: @MainActor @escaping (String) -> Void
    ) async throws -> String {
        guard let key = apiKey else { throw RewriteError.noKey }

        var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "temperature": 0.4,
            // Without a cap Groq reserves the model's whole output window against the per-minute
            // token limit and rejects the request as "too large". A prompt never needs more than this.
            // Free tier allows 1000 output tokens per minute for some models, per request as well.
            "max_completion_tokens": 900,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Dictated request:\n\"\"\"\n\(dictation)\n\"\"\""],
            ],
        ]
        // Reasoning models (Qwen 3 etc.) would otherwise stream their <think> block first.
        body["reasoning_format"] = "hidden"

        do {
            return try await stream(request, body: body, onDelta: onDelta)
        } catch RewriteError.http(400, let message) where message.contains("reasoning") {
            // Model doesn't support the reasoning switch: retry without it (think blocks get stripped).
            body.removeValue(forKey: "reasoning_format")
            return try await stream(request, body: body, onDelta: onDelta)
        }
    }

    private static func stream(
        _ request: URLRequest, body: [String: Any], onDelta: @MainActor @escaping (String) -> Void
    ) async throws -> String {
        var request = request
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var text = ""
            for try await line in bytes.lines { text += line }
            throw RewriteError.http(status, text)
        }

        var raw = ""
        var shown = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = line.dropFirst(6)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choice = (json["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any],
                  let piece = delta["content"] as? String else { continue }
            raw += piece
            if ProcessInfo.processInfo.environment["LW_DEBUG"] != nil, let usage = (json["x_groq"] as? [String: Any])?["usage"] {
                print("usage: \(usage)")
            }
            let visible = stripThinking(raw)
            if visible.count > shown.count, visible.hasPrefix(shown) {
                let newText = String(visible.dropFirst(shown.count))
                shown = visible
                await onDelta(newText)
            }
        }
        let result = stripThinking(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw RewriteError.empty }
        return result
    }

    /// Removes a `<think>…</think>` block (and hides an unfinished one while it's still streaming).
    static func stripThinking(_ text: String) -> String {
        guard let open = text.range(of: "<think>") else { return text }
        guard let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) else {
            return String(text[..<open.lowerBound])
        }
        let after = text[close.upperBound...].drop { $0.isWhitespace || $0.isNewline }
        return String(text[..<open.lowerBound]) + after
    }

    /// Model ids available on the account, Qwen models first.
    static func availableModels() async throws -> [String] {
        guard let key = apiKey else { throw RewriteError.noKey }
        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw RewriteError.http(status, String(decoding: data, as: UTF8.self)) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let ids = (json?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        let chat = ids.filter { id in
            let l = id.lowercased()
            return !["whisper", "tts", "guard", "embed", "orpheus", "prompt-guard"].contains { l.contains($0) }
        }
        return chat.sorted { a, b in
            let qa = a.lowercased().contains("qwen"), qb = b.lowercased().contains("qwen")
            return qa != qb ? qa : a < b
        }
    }
}
