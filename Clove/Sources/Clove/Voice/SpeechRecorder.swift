import AVFoundation
import Speech

enum SpeechRecorderError: LocalizedError {
    case microphoneDenied
    case unavailable
    case noAudioFormat

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access is off. Allow it in System Settings → Privacy & Security → Microphone."
        case .unavailable: "On-device speech recognition isn't available on this Mac."
        case .noAudioFormat: "Couldn't set up the microphone for transcription."
        }
    }
}

/// Records from the microphone and transcribes on this Mac with Apple's SpeechAnalyzer, which
/// handles long, rambling notes well. Audio never leaves the device.
@MainActor
final class SpeechRecorder {
    /// Called with the running transcript as the speaker talks.
    var onTranscript: ((String) -> Void)?
    /// Called with download progress (0...1) the first time the speech model is fetched.
    var onPreparing: ((Double) -> Void)?
    /// Called about ten times a second with the microphone level (0...1), for the waveform.
    var onLevel: ((Double) -> Void)?

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var finalized = ""
    private var volatile = ""

    private var transcript: String {
        (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func requestPermission() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw SpeechRecorderError.microphoneDenied }
    }

    /// - Parameter vocabulary: Names worth recognizing, like issue titles and project names.
    func start(vocabulary: [String]) async throws {
        guard SpeechTranscriber.isAvailable else { throw SpeechRecorderError.unavailable }
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])

        // First use downloads the on-device model for this language.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let progress = request.progress
            let reporter = Task { [weak self] in
                while !Task.isCancelled {
                    self?.onPreparing?(progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { reporter.cancel() }
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try? await analyzer.setContext(context)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechRecorderError.noAudioFormat
        }

        finalized = ""
        volatile = ""
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard let self else { return }
                    if result.isFinal {
                        self.finalized += text
                        self.volatile = ""
                    } else {
                        self.volatile = text
                    }
                    self.onTranscript?(self.transcript)
                }
            } catch {
                // The stream ends with an error when cancelled; the transcript so far is kept.
            }
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer

        let node = engine.inputNode
        let micFormat = node.outputFormat(forBus: 0)
        let converter = micFormat == format ? nil : AVAudioConverter(from: micFormat, to: format)
        node.installTap(onBus: 0, bufferSize: 4096, format: micFormat,
                        block: Self.tapBlock(converter: converter, format: format, feeding: continuation, reportingTo: self))
        engine.prepare()
        try engine.start()
    }

    /// The tap runs on a realtime audio thread, so it's built outside the main actor. It converts
    /// microphone audio to the format the analyzer wants and feeds it in.
    nonisolated private static func tapBlock(converter: AVAudioConverter?, format: AVAudioFormat, feeding input: AsyncStream<AnalyzerInput>.Continuation,
                                             reportingTo recorder: SpeechRecorder) -> AVAudioNodeTapBlock {
        { [weak recorder] buffer, _ in
            let level = Self.level(of: buffer)
            Task { @MainActor in recorder?.onLevel?(level) }

            guard let converter else {
                input.yield(AnalyzerInput(buffer: buffer))
                return
            }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, converted.frameLength > 0 {
                input.yield(AnalyzerInput(buffer: converted))
            }
        }
    }

    /// Loudness of a buffer mapped to 0...1 (about -50 dB to -5 dB), for a lively waveform.
    nonisolated private static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        return Double(min(max((decibels + 50) / 45, 0), 1))
    }

    /// Stops listening and returns the final transcript once the analyzer has finished.
    func stop() async -> String {
        stopAudio()
        input?.finish()
        input = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        // Give the last results a moment to arrive, but never hang the panel.
        let results = resultsTask
        let timeout = Task { try? await Task.sleep(for: .seconds(3)); results?.cancel() }
        await results?.value
        timeout.cancel()
        analyzer = nil
        resultsTask = nil
        return transcript
    }

    func cancel() {
        stopAudio()
        input?.finish()
        input = nil
        let analyzer = analyzer
        Task { await analyzer?.cancelAndFinishNow() }
        self.analyzer = nil
        resultsTask?.cancel()
        resultsTask = nil
    }

    private func stopAudio() {
        guard engine.isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }
}
