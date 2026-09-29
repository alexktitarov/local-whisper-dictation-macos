import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Phase { case loading, idle, recording, transcribing, error }

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let hotkey = HotkeyMonitor()
    private let hud = RecordingHUD()
    private let stats = StatsStore()

    private var loadTask: Task<Void, Error>?
    private var statusText = "Starting…"
    private var accessibilityPoll: Timer?
    private var isModelReady = false
    private var phase: Phase = .loading { didSet { refreshIcon() } }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refreshIcon()

        recorder.onLevel = { [weak self] level in self?.hud.push(level: level) }
        hotkey.onStart = { [weak self] promptMode in self?.startRecording(promptMode: promptMode) }
        hotkey.onPromptMode = { [weak self] in self?.switchToPromptMode() }
        hotkey.onEscapeWhileIdle = { [weak self] in self?.rewriteTask?.cancel() }
        hotkey.onStop = { [weak self] in self?.finishRecording() }
        hotkey.onCancel = { [weak self] in self?.cancelRecording() }
        hotkey.start()

        Task {
            if !(await AudioRecorder.requestPermission()) {
                setStatus("Microphone access denied")
            }
        }

        if !Paster.hasAccessibility {
            Paster.promptForAccessibility()
            waitForAccessibility()
        }

        loadModel()
        refreshPromptModels()
    }

    // MARK: - Recording flow

    private var session: StreamingSession?
    /// ⇧ was held when the recording started: the dictation becomes a prompt for ChatGPT / Claude.
    private var promptMode = false

    private func startRecording(latched: Bool = false, promptMode: Bool = false) {
        guard !recorder.isRecording else { return }
        stats.refreshMic()
        do {
            try recorder.start()
        } catch {
            hotkey.reset()
            hud.message("Mic error: \(error.localizedDescription)", symbol: "mic.slash.fill")
            return
        }
        playSound("Tink")
        phase = .recording
        self.promptMode = promptMode
        hud.promptMode = promptMode
        hud.show(.listening(latched: latched))
        startSession()
        guard !latched else { return }
        // A quick tap leaves recording on (hands-free); switch the hint once the tap window has passed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.recorder.isRecording, !NSEvent.modifierFlags.contains(.option) else { return }
            self.hud.show(.listening(latched: true))
        }
    }

    /// ⇧ pressed after recording already started (⌥ first, then ⇧).
    private func switchToPromptMode() {
        guard recorder.isRecording, !promptMode, let session else { return }
        // Words already typed into the target app can't be taken back, so it stays a plain dictation.
        guard !session.hasTyped else { return }
        promptMode = true
        session.typesLive = false
        hud.promptMode = true
    }

    private func startSession() {
        let recorder = recorder
        let session = StreamingSession(
            transcriber: transcriber, language: Settings.language, vocabulary: Settings.vocabulary,
            waitForModel: { [weak self] in try await self?.loadTask?.value },
            samples: { recorder.snapshot() }
        )
        // Prompt mode rewrites the text afterwards, so nothing may be typed live.
        session.typesLive = Settings.liveTyping && Typer.canType && !promptMode
        session.onUpdate = { [weak self] committed, tentative in
            self?.hud.setLiveText(committed: committed, tentative: tentative)
        }
        session.onCommit = { [weak session] delta in
            guard let session, session.typesLive else { return }
            session.hasTyped = true
            Typer.type(delta)
        }
        self.session = session
        session.start()
    }

    private func cancelRecording() {
        _ = recorder.stop()
        session?.cancel()
        session = nil
        phase = isModelReady ? .idle : .loading
        hud.message("Cancelled", symbol: "xmark.circle.fill")
    }

    private func finishRecording() {
        let samples = recorder.stop()
        playSound("Pop")
        guard let session else { return }
        self.session = nil
        let promptMode = self.promptMode

        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        guard seconds >= 0.3, samples.peakWindowRMS > 0.008 else {
            session.cancel()
            phase = isModelReady ? .idle : .loading
            hud.message("Didn't catch that", symbol: "ear.trianglebadge.exclamationmark")
            return
        }

        phase = .transcribing
        hud.show(.transcribing)

        Task {
            let started = Date()
            var text = ""
            var language = session.reportedLanguage ?? Settings.whisperLanguage(for: Settings.language) ?? "?"
            if session.typesLive {
                text = await session.finish(with: samples)
            } else {
                // Nothing was typed yet, so we can afford the best result: one pass over the whole
                // recording. Much more reliable than the live stream for long or mixed-language speech.
                session.cancel()
                do {
                    try await loadTask?.value
                    let output = try await transcriber.transcribe(samples, language: Settings.language, vocabulary: Settings.vocabulary)
                    text = output.text
                    language = output.language
                } catch {
                    text = await session.finish(with: samples)
                }
            }
            let elapsed = Date().timeIntervalSince(started)
            NSLog("LocalWhisper: %.1fs audio, final %.2fs after release [%@]: %@", seconds, elapsed, language, text)

            phase = .idle
            guard !text.isEmpty else {
                hud.message("Didn't catch that", symbol: "ear.trianglebadge.exclamationmark")
                return
            }
            stats.add(DictationRecord(
                date: Date(), audioSeconds: seconds, transcribeSeconds: elapsed,
                words: text.split(whereSeparator: \.isWhitespace).count,
                language: language, text: text
            ))

            if session.typesLive {
                hud.hide() // already typed word by word
                return
            }
            if promptMode {
                rewriteAndPaste(text)
                return
            }
            switch Paster.insert(text) {
            case .pasted: hud.hide()
            case .copiedOnly(let reason): hud.message(reason, symbol: "doc.on.clipboard.fill")
            }
        }
    }

    // MARK: - Prompt mode

    private var rewriteTask: Task<Void, Never>?
    private var promptModels: [String] = []

    /// Streams the LLM-written prompt into the HUD, then pastes it (never presses Enter).
    /// Esc, a missing key or any error falls back to pasting the plain dictation.
    private func rewriteAndPaste(_ dictation: String) {
        hud.setLiveText(committed: "", tentative: "")
        hud.show(.rewriting)
        phase = .transcribing

        rewriteTask = Task {
            var result = dictation
            var problem: String?
            do {
                let model = try await resolvePromptModel()
                var streamed = ""
                result = try await PromptRewriter.rewrite(dictation, model: model) { [weak self] delta in
                    streamed += delta
                    self?.hud.setLiveText(committed: streamed, tentative: "")
                }
            } catch is CancellationError {
                problem = "Pasted as dictated"
            } catch let error as URLError where error.code == .cancelled {
                problem = "Pasted as dictated"
            } catch {
                NSLog("LocalWhisper: prompt rewrite failed: %@", "\(error)")
                problem = error.localizedDescription
            }
            rewriteTask = nil
            phase = .idle

            switch Paster.insert(result) {
            case .pasted:
                if let problem { hud.message(problem, symbol: "sparkles") } else { hud.hide() }
            case .copiedOnly(let reason):
                hud.message(reason, symbol: "doc.on.clipboard.fill")
            }
        }
    }

    private func resolvePromptModel() async throws -> String {
        if let model = Settings.promptModel { return model }
        if promptModels.isEmpty { promptModels = try await PromptRewriter.availableModels() }
        guard let first = promptModels.first else { throw PromptRewriter.RewriteError.empty }
        Settings.promptModel = first
        return first
    }

    private func refreshPromptModels() {
        guard PromptRewriter.apiKey != nil else { promptModels = []; return }
        Task {
            do {
                promptModels = try await PromptRewriter.availableModels()
                if Settings.promptModel == nil { Settings.promptModel = promptModels.first }
            } catch {
                NSLog("LocalWhisper: couldn't list Groq models: %@", "\(error)")
            }
        }
    }

    // MARK: - Model

    private func loadModel() {
        isModelReady = false
        stats.modelReady = false
        stats.modelName = Settings.modelID
        phase = .loading
        let model = Settings.modelID
        loadTask = Task {
            do {
                try await transcriber.load(model: model) { message in
                    Task { @MainActor in self.stats.modelState = message }
                }
                isModelReady = true
                stats.modelReady = true
                if phase == .loading { phase = .idle }
                setStatus("Local Whisper ready")
            } catch {
                phase = .error
                stats.modelState = "Failed to load"
                setStatus("Model failed: \(error.localizedDescription)")
                throw error
            }
        }
        setStatus("Loading model…")
    }

    // MARK: - Permissions

    private func waitForAccessibility() {
        accessibilityPoll?.invalidate()
        accessibilityPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, Paster.hasAccessibility else { return }
                timer.invalidate()
                self.hotkey.start() // global monitors only deliver events once trusted
            }
        }
    }

    // MARK: - Status item

    private func setStatus(_ text: String) {
        statusText = text
    }

    private func refreshIcon() {
        let symbol: String
        switch phase {
        case .loading: symbol = "arrow.down.circle"
        case .idle: symbol = "waveform"
        case .recording: symbol = "waveform.badge.mic"
        case .transcribing: symbol = "ellipsis.circle"
        case .error: symbol = "exclamationmark.triangle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Local Whisper")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        populate(menu)
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(disabled(statusText))
        menu.addItem(.separator())

        if recorder.isRecording {
            menu.addItem(item("Stop Dictation", #selector(toggleDictation)))
        } else {
            let start = item("Start Dictation", #selector(toggleDictation))
            start.isEnabled = isModelReady
            menu.addItem(start)
        }
        menu.addItem(submenu("Model", modelMenu()))
        menu.addItem(submenu("Language", languageMenu()))
        menu.addItem(.separator())

        menu.addItem(submenu("Stats", panelMenu()))
        menu.addItem(submenu("History", historyMenu()))
        menu.addItem(.separator())

        if !Paster.hasAccessibility {
            menu.addItem(item("Grant Accessibility…", #selector(openAccessibility)))
        }
        menu.addItem(submenu("Prompt Mode", promptMenu()))
        menu.addItem(item("Custom Vocabulary…", #selector(editVocabulary)))
        let live = item("Type as You Speak", #selector(toggleLiveTyping))
        live.state = Settings.liveTyping ? .on : .off
        menu.addItem(live)
        let sounds = item("Play Sounds", #selector(toggleSounds))
        sounds.state = Settings.playSounds ? .on : .off
        menu.addItem(sounds)
        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        menu.addItem(disabled("Hold right ⌥ to talk · tap for hands-free"))
        menu.addItem(item("Quit Local Whisper", #selector(quit), key: "q"))
    }

    private func panelMenu() -> NSMenu {
        let sub = NSMenu()
        let host = NSHostingView(rootView: StatsPanel(store: stats))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let panelItem = NSMenuItem()
        panelItem.view = host
        sub.addItem(panelItem)
        return sub
    }

    private func modelMenu() -> NSMenu {
        let sub = NSMenu()
        for option in Settings.models {
            let mi = item(option.title, #selector(selectModel(_:)))
            mi.representedObject = option.id
            mi.state = option.id == Settings.modelID ? .on : .off
            sub.addItem(mi)
        }
        return sub
    }

    private func languageMenu() -> NSMenu {
        let sub = NSMenu()
        for lang in Settings.languages {
            let mi = item(lang.title, #selector(selectLanguage(_:)))
            mi.representedObject = lang.code
            mi.state = lang.code == Settings.language ? .on : .off
            sub.addItem(mi)
        }
        return sub
    }

    private func historyMenu() -> NSMenu {
        let sub = NSMenu()
        let recent = stats.records.suffix(12).reversed()
        if recent.isEmpty {
            sub.addItem(disabled("Nothing yet"))
            return sub
        }
        sub.addItem(disabled("Click to copy"))
        let timeFormat = Date.FormatStyle(date: .omitted, time: .shortened)
        for record in recent {
            let preview = record.text.count > 48 ? String(record.text.prefix(48)) + "…" : record.text
            let mi = item(preview, #selector(copyHistory(_:)))
            mi.representedObject = record.text
            mi.toolTip = record.text
            let attributed = NSMutableAttributedString(string: preview + "  ", attributes: [.font: NSFont.menuFont(ofSize: 0)])
            attributed.append(NSAttributedString(string: record.date.formatted(timeFormat), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
            mi.attributedTitle = attributed
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        sub.addItem(item("Clear History", #selector(clearHistory)))
        return sub
    }

    private func promptMenu() -> NSMenu {
        let sub = NSMenu()
        sub.addItem(disabled("Hold ⇧ + right ⌥ to dictate a prompt"))
        sub.addItem(.separator())
        let hasKey = PromptRewriter.apiKey != nil
        let keyItem = item(hasKey ? "Groq API Key ✓" : "Set Groq API Key…", #selector(editGroqKey))
        sub.addItem(keyItem)

        let models = NSMenu()
        if !hasKey {
            models.addItem(disabled("Set the API key first"))
        } else if promptModels.isEmpty {
            models.addItem(disabled("Loading…"))
            refreshPromptModels()
        } else {
            for id in promptModels {
                let mi = item(id, #selector(selectPromptModel(_:)))
                mi.representedObject = id
                mi.state = id == Settings.promptModel ? .on : .off
                models.addItem(mi)
            }
        }
        sub.addItem(submenu("Model", models))
        return sub
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.submenu = sub
        return mi
    }

    // MARK: - Menu actions

    @objc private func toggleDictation() {
        if recorder.isRecording {
            hotkey.reset()
            finishRecording()
        } else {
            hotkey.latch()
            startRecording(latched: true)
        }
    }

    @objc private func openAccessibility() {
        Paster.promptForAccessibility()
        Paster.openAccessibilitySettings()
        waitForAccessibility()
    }

    @objc private func copyHistory(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        hud.message("Copied", symbol: "doc.on.clipboard.fill")
    }

    @objc private func clearHistory() { stats.clearHistory() }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != Settings.modelID else { return }
        Settings.modelID = id
        loadModel()
        refreshPromptModels()
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        Settings.language = sender.representedObject as? String
    }

    @objc private func editVocabulary() {
        let alert = NSAlert()
        alert.messageText = "Custom Vocabulary"
        alert.informativeText = "Names and terms Whisper should spell right, separated by commas.\ne.g. WhisperKit, Kubernetes, PostgreSQL"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = Settings.vocabulary
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            Settings.vocabulary = field.stringValue
        }
    }

    @objc private func editGroqKey() {
        let alert = NSAlert()
        alert.messageText = "Groq API Key"
        alert.informativeText = "Used only to turn ⇧ + right ⌥ dictations into prompts. Stored in your Keychain.\nLeave empty and Save to remove it."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = PromptRewriter.apiKey == nil ? "gsk_…" : "•••••••• (saved)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.write(value, for: PromptRewriter.keychainAccount) // empty value removes the key
        promptModels = []
        refreshPromptModels()
    }

    @objc private func selectPromptModel(_ sender: NSMenuItem) {
        Settings.promptModel = sender.representedObject as? String
    }

    @objc private func toggleLiveTyping() { Settings.liveTyping.toggle() }

    @objc private func toggleSounds() { Settings.playSounds.toggle() }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            hud.message("Launch at login failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func playSound(_ name: String) {
        guard Settings.playSounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
