import AppKit
import SwiftUI

/// Floating pill at the bottom of the screen with a live waveform. Never takes focus, ignores clicks.
@MainActor
final class RecordingHUD {
    enum State: Equatable {
        case listening(latched: Bool)
        case transcribing
        /// Prompt mode: the LLM is writing the prompt (streamed into the caption).
        case rewriting
        case message(String, symbol: String)
    }

    /// Marks the current recording as prompt mode (shows a ✨ badge).
    var promptMode: Bool {
        get { model.promptMode }
        set { model.promptMode = newValue }
    }

    private let model = HUDModel()
    private lazy var panel: NSPanel = makePanel()
    private var hideWork: DispatchWorkItem?

    func show(_ state: State) {
        hideWork?.cancel()
        if case .listening = state, !isListening { model.startListening() }
        model.state = state
        position()
        panel.orderFrontRegardless()
        if case .message = state {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
        }
    }

    func message(_ text: String, symbol: String = "info.circle.fill") {
        show(.message(text, symbol: symbol))
    }

    func push(level: Float) { model.push(CGFloat(level)) }

    func setLiveText(committed: String, tentative: String) {
        model.committed = committed
        model.tentative = tentative
    }

    func hide() {
        hideWork?.cancel()
        panel.orderOut(nil)
    }

    private var isListening: Bool {
        if case .listening = model.state { return panel.isVisible }
        return false
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 190),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        return panel
    }

    private func position() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 36))
    }
}

@MainActor
final class HUDModel: ObservableObject {
    static let barCount = 26

    @Published var state: RecordingHUD.State = .transcribing
    @Published var levels = [CGFloat](repeating: 0, count: HUDModel.barCount)
    @Published var startedAt = Date()
    @Published var committed = ""
    @Published var tentative = ""
    @Published var promptMode = false

    func startListening() {
        levels = [CGFloat](repeating: 0, count: Self.barCount)
        startedAt = Date()
        committed = ""
        tentative = ""
    }

    func push(_ level: CGFloat) {
        // Light smoothing so the bars glide instead of flicker.
        let smoothed = (levels.last ?? 0) * 0.35 + level * 0.65
        levels.removeFirst()
        levels.append(smoothed)
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            if showsCaption { caption.transition(.opacity.combined(with: .move(edge: .bottom))) }
            pill
        }
        .padding(.bottom, 12)
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.state)
        .animation(.easeOut(duration: 0.15), value: model.committed + model.tentative)
    }

    private var showsCaption: Bool {
        if case .message = model.state { return false }
        return !(model.committed.isEmpty && model.tentative.isEmpty)
    }

    /// Live transcript: committed words bright, the still-changing tail dimmed.
    private var caption: some View {
        let rewriting = model.state == .rewriting
        // While a prompt streams in, keep its newest lines in view.
        let source = rewriting ? model.committed.components(separatedBy: "\n").suffix(6).joined(separator: "\n") : model.committed
        let (committed, tentative) = Self.tail(source, model.tentative, limit: rewriting ? 420 : 220)
        return (Text(committed).foregroundColor(.white) + Text(tentative).foregroundColor(.white.opacity(0.45)))
            .font(.system(size: 14, weight: .medium))
            .lineSpacing(2)
            .lineLimit(rewriting ? 6 : 3)
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 540, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.black.opacity(0.78))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            )
    }

    /// Keeps only the last `limit` characters so the newest words stay visible.
    private static func tail(_ committed: String, _ tentative: String, limit: Int) -> (String, String) {
        let total = committed.count + tentative.count
        guard total > limit else { return (committed, tentative) }
        let drop = total - limit
        if drop >= committed.count { return ("", "…" + String(tentative.dropFirst(drop - committed.count))) }
        return ("…" + String(committed.dropFirst(drop)), tentative)
    }

    private var pill: some View {
        HStack(spacing: 12) {
            leading
            content
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .frame(height: 40)
        .background(
            Capsule()
                .fill(.black.opacity(0.78))
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        )
    }

    @ViewBuilder private var leading: some View {
        switch model.state {
        case .listening:
            PulsingDot()
        case .transcribing, .rewriting:
            Image(systemName: "sparkles").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.cyan)
        case .message(_, let symbol):
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(.white.opacity(0.9))
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .listening(let latched):
            Waveform(levels: model.levels, tint: .white)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(elapsed(ctx.date))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
            if latched {
                Text("tap ⌥ to finish")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            if model.promptMode {
                Label("Prompt", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.cyan)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Palette.cyan.opacity(0.15)))
            }
        case .transcribing:
            ShimmerWave()
            Text("Transcribing")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        case .rewriting:
            ShimmerWave()
            Text("Improving prompt · Esc = paste as is")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        case .message(let text, _):
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    private func elapsed(_ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(model.startedAt)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        ZStack {
            Circle().fill(Palette.red.opacity(0.35)).frame(width: 18, height: 18).scaleEffect(on ? 1 : 0.5)
            Circle().fill(Palette.red).frame(width: 9, height: 9)
        }
        .frame(width: 18, height: 18)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { on = true }
        }
    }
}

private struct Waveform: View {
    let levels: [CGFloat]
    let tint: Color
    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(tint.opacity(0.35 + 0.65 * level))
                    .frame(width: 3, height: 3 + level * 22)
            }
        }
        .frame(height: 26)
        .animation(.linear(duration: 0.1), value: levels)
    }
}

/// Idle "thinking" wave while Whisper runs.
private struct ShimmerWave: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<14, id: \.self) { i in
                    let phase = sin(t * 6 - Double(i) * 0.55)
                    Capsule()
                        .fill(LinearGradient(colors: [Palette.cyan, Palette.blue], startPoint: .top, endPoint: .bottom))
                        .frame(width: 3, height: 5 + CGFloat((phase + 1) / 2) * 14)
                        .opacity(0.5 + (phase + 1) / 4)
                }
            }
            .frame(height: 26)
        }
    }
}
