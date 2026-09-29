import AVFoundation

/// Captures mic audio and converts it on the fly to 16 kHz mono Float32, which is what Whisper expects.
final class AudioRecorder {
    static let sampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false
    )!

    private(set) var isRecording = false

    /// Called on the main thread ~10×/s with a 0…1 loudness value, for the HUD waveform.
    var onLevel: ((Float) -> Void)?

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        guard !isRecording else { return }
        lock.withLock { samples.removeAll(keepingCapacity: true) }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw RecorderError.noInputDevice }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRecording = true
    }

    /// Stops recording and returns the captured 16 kHz samples.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        return lock.withLock { samples }
    }

    /// Everything captured so far, without stopping.
    func snapshot() -> [Float] { lock.withLock { samples } }

    var sampleCount: Int { lock.withLock { samples.count } }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: data, count: Int(out.frameLength))
        lock.withLock { samples.append(contentsOf: chunk) }

        if let onLevel {
            // Map RMS (≈0.001 quiet … 0.3 loud) onto a perceptual 0…1 scale.
            let db = 20 * log10(Swift.max(Array(chunk).rms, 1e-5))
            let level = Swift.min(Swift.max((db + 55) / 45, 0), 1)
            DispatchQueue.main.async { onLevel(level) }
        }
    }

    enum RecorderError: LocalizedError {
        case noInputDevice
        var errorDescription: String? { "No microphone input device found." }
    }
}

extension Array where Element == Float {
    var rms: Float {
        guard !isEmpty else { return 0 }
        var sum: Float = 0
        for s in self { sum += s * s }
        return (sum / Float(count)).squareRoot()
    }

    /// Loudest 100 ms window, used to decide whether anything was actually said.
    var peakWindowRMS: Float {
        let window = Int(AudioRecorder.sampleRate / 10)
        guard count > window else { return rms }
        var best: Float = 0
        var i = 0
        while i + window <= count {
            best = Swift.max(best, Array(self[i..<i + window]).rms)
            i += window / 2
        }
        return best
    }
}
