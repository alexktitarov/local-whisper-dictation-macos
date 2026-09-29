import SwiftUI

enum Palette {
    static let amber = Color(red: 1.0, green: 0.62, blue: 0.26)
    static let blue = Color(red: 0.25, green: 0.52, blue: 1.0)
    static let green = Color(red: 0.36, green: 0.84, blue: 0.42)
    static let cyan = Color(red: 0.35, green: 0.78, blue: 0.98)
    static let red = Color(red: 0.93, green: 0.30, blue: 0.30)
    static let purple = Color(red: 0.78, green: 0.30, blue: 0.93)
    static let header = Color(red: 0.25, green: 0.52, blue: 1.0)
    static let track = Color.primary.opacity(0.10)

    static let languages: [Color] = [blue, red, purple, amber, green, cyan]
}

// MARK: - Panel

/// The big "Stats ›" submenu panel, oMLX-style.
struct StatsPanel: View {
    @ObservedObject var store: StatsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            lastDictation
            SectionDivider()
            todaySection
            SectionDivider()
            languagesSection
            SectionDivider()
            modelSection
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 290)
    }

    // MARK: Sections

    @ViewBuilder private var lastDictation: some View {
        SectionHeader("LAST DICTATION")
        if let last = store.last {
            MeterRow(label: "Speed", value: String(format: "%.0f× realtime", last.realtimeFactor),
                     fraction: min(last.realtimeFactor / 40, 1), color: Palette.amber)
            MeterRow(label: "Latency", value: String(format: "%.2f s", last.transcribeSeconds),
                     fraction: min(last.transcribeSeconds / 3, 1), color: Palette.blue)
            Footnote("latency (amber) / audio length (blue) · last \(store.recent.count)")
            Sparkline(series: [
                (store.recent.map(\.transcribeSeconds), Palette.amber),
                (store.recent.map(\.audioSeconds), Palette.blue),
            ])
            .frame(height: 34)
            .padding(.vertical, 8)
            StatRow(label: "Language", value: languageName(last.language))
            StatRow(label: "Audio", value: String(format: "%.1f s", last.audioSeconds))
            StatRow(label: "Words", value: "\(last.words)")
        } else {
            Text("No dictations yet.\nHold right ⌥ and say something.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.vertical, 10)
        }
    }

    @ViewBuilder private var todaySection: some View {
        SectionHeader("TODAY")
        HStack(alignment: .firstTextBaseline) {
            Text("\(store.todayWords.formatted()) words")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
            Spacer()
            Text(savedLabel)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 6)
        Bar(fraction: min(Double(store.todayWords) / 2000, 1), color: Palette.green)
            .padding(.bottom, 4)
        Footnote("goal: 2,000 words · typing at \(Int(StatsStore.typingWPM)) wpm")
        StatRow(label: "Dictations", value: "\(store.today.count)")
        StatRow(label: "Speaking", value: durationLabel(store.todaySpeaking))
        StatRow(label: "Avg latency", value: store.recent.isEmpty ? "—" : String(format: "%.2f s", store.avgLatency))
    }

    @ViewBuilder private var languagesSection: some View {
        let breakdown = Array(store.languageBreakdown.prefix(Palette.languages.count))
        let total = max(breakdown.reduce(0) { $0 + $1.words }, 1)

        SectionHeader("LANGUAGES")
        HStack(alignment: .firstTextBaseline) {
            Text("\(store.allTimeWords.formatted()) words")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
            Spacer()
            Text("all time").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.bottom, 6)
        StackedBar(segments: breakdown.enumerated().map { i, entry in
            (Double(entry.words) / Double(total), Palette.languages[i])
        })
        .padding(.bottom, 6)
        if breakdown.isEmpty {
            LegendRow(color: Palette.track, label: "Nothing yet", value: "")
        }
        ForEach(Array(breakdown.enumerated()), id: \.offset) { i, entry in
            LegendRow(color: Palette.languages[i], label: languageName(entry.language),
                      value: "\(Int((Double(entry.words) / Double(total) * 100).rounded()))%")
        }
    }

    @ViewBuilder private var modelSection: some View {
        SectionHeader("ENGINE")
        HStack {
            Circle()
                .fill(store.modelReady ? Palette.green : Palette.amber)
                .frame(width: 7, height: 7)
            Text(store.modelReady ? "Loaded · Neural Engine" : store.modelState)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.bottom, 6)
        StatRow(label: "Model", value: Settings.models.first { $0.id == store.modelName }?.shortTitle ?? store.modelName)
        StatRow(label: "On disk", value: store.modelSizeOnDisk)
        StatRow(label: "Mic", value: store.micName)
    }

    // MARK: Helpers

    private var savedLabel: String {
        let m = store.todayMinutesSaved
        return m < 1 ? "just getting started" : "~\(Int(m.rounded())) min saved"
    }

    private func durationLabel(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }

    private func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }
}

// MARK: - Building blocks

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .tracking(1.8)
            .foregroundStyle(Palette.header)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 8)
    }
}

struct SectionDivider: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).padding(.vertical, 10)
    }
}

struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 10)).foregroundStyle(.tertiary).padding(.bottom, 2)
    }
}

struct StatRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 12.5))
        .padding(.vertical, 2)
    }
}

struct MeterRow: View {
    let label: String
    let value: String
    let fraction: Double
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(value).font(.system(size: 12.5, design: .monospaced))
            }
            Bar(fraction: fraction, color: color)
        }
        .padding(.bottom, 8)
    }
}

struct Bar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(color).frame(width: max(6, geo.size.width * fraction))
            }
        }
        .frame(height: 5)
    }
}

struct StackedBar: View {
    let segments: [(fraction: Double, color: Color)]
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    Rectangle().fill(seg.color).frame(width: max(2, geo.size.width * seg.fraction - 1.5))
                }
                Spacer(minLength: 0)
            }
            .background(Palette.track)
            .clipShape(Capsule())
        }
        .frame(height: 9)
    }
}

struct LegendRow: View {
    let color: Color
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12.5, design: .monospaced))
        }
        .font(.system(size: 12.5))
        .padding(.vertical, 2)
    }
}

/// Multi-series line chart, each series on its own y-scale, with a faint fill under the first one.
struct Sparkline: View {
    let series: [(values: [Double], color: Color)]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Array(series.enumerated()), id: \.offset) { i, s in
                    let maxV = max((s.values.max() ?? 1) * 1.15, 0.001)
                    if i == 0 {
                        path(s.values, in: geo.size, maxV: maxV, closed: true)
                            .fill(LinearGradient(colors: [s.color.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                    }
                    path(s.values, in: geo.size, maxV: maxV, closed: false)
                        .stroke(s.color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func path(_ values: [Double], in size: CGSize, maxV: Double, closed: Bool) -> Path {
        Path { p in
            let pts = values.count == 1 ? [values[0], values[0]] : values
            guard pts.count > 1 else { return }
            let step = size.width / CGFloat(pts.count - 1)
            func y(_ v: Double) -> CGFloat { size.height - CGFloat(v / maxV) * (size.height - 2) - 1 }
            p.move(to: CGPoint(x: 0, y: y(pts[0])))
            for (i, v) in pts.enumerated().dropFirst() {
                p.addLine(to: CGPoint(x: CGFloat(i) * step, y: y(v)))
            }
            if closed {
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.addLine(to: CGPoint(x: 0, y: size.height))
                p.closeSubpath()
            }
        }
    }
}
