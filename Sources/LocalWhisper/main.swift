import AppKit

import WhisperKit

// `LocalWhisper --transcribe <audio file>`: runs the same pipeline as the hotkey, for testing.
if let i = CommandLine.arguments.firstIndex(of: "--transcribe"), i + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[i + 1]
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
            let t = Transcriber()
            try await t.load(model: Settings.modelID) { _ in }
            let start = Date()
            let out = try await t.transcribe(samples, language: Settings.language, vocabulary: Settings.vocabulary)
            print(String(format: "[%@] %.2fs: %@", out.language, Date().timeIntervalSince(start), out.text))
        } catch {
            print("error: \(error)")
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

// `LocalWhisper --rewrite-test "<dictation>"`: prompt-mode rewrite via Groq, using the key from Keychain.
if let i = CommandLine.arguments.firstIndex(of: "--rewrite-test"), i + 1 < CommandLine.arguments.count {
    let dictation = CommandLine.arguments[i + 1]
    Task { @MainActor in
        do {
            let models = try await PromptRewriter.availableModels()
            print("models: \(models.joined(separator: ", "))")
            let model = Settings.promptModel ?? models.first ?? ""
            let t0 = Date()
            var first: TimeInterval?
            let out = try await PromptRewriter.rewrite(dictation, model: model) { _ in
                if first == nil { first = Date().timeIntervalSince(t0) }
            }
            print(String(format: "model %@ · first text %.2fs · total %.2fs\n---\n%@", model, first ?? 0, Date().timeIntervalSince(t0), out))
        } catch {
            print("error: \(error.localizedDescription)")
        }
        exit(0)
    }
    dispatchMain()
}

// `LocalWhisper --stream-test <audio file>`: replays the file in real time through the live pipeline.
if let i = CommandLine.arguments.firstIndex(of: "--stream-test"), i + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[i + 1]
    let env = ProcessInfo.processInfo.environment
    Task { @MainActor in
        do {
            let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
            let t = Transcriber()
            try await t.load(model: Settings.modelID) { _ in }
            var fed = 0
            let session = StreamingSession(
                transcriber: t, language: env["LW_LANG"] ?? Settings.language, vocabulary: env["LW_VOCAB"] ?? "",
                waitForModel: {}, samples: { Array(audio.prefix(fed)) }
            )
            session.lockLanguage = env["LW_NOLOCK"] == nil
            let t0 = Date()
            session.onCommit = { delta in
                print(String(format: "%5.2fs  audio@%5.2fs  +%@", Date().timeIntervalSince(t0), Double(fed) / 16000, delta))
            }
            session.start()
            while fed < audio.count {
                try await Task.sleep(for: .milliseconds(50))
                fed = min(audio.count, Int(Date().timeIntervalSince(t0) * 16000))
            }
            let released = Date()
            let text = await session.finish(with: audio)
            print(String(format: "final %.2fs after release: %@", Date().timeIntervalSince(released), text))
        } catch {
            print("error: \(error)")
        }
        exit(0)
    }
    dispatchMain()
}

MainActor.assumeIsolated {
    if let i = CommandLine.arguments.firstIndex(of: "--render-previews"), i + 1 < CommandLine.arguments.count {
        renderPreviews(to: CommandLine.arguments[i + 1])
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
    app.run()
}
