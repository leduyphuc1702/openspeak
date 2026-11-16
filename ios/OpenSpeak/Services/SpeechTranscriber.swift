@preconcurrency import AVFoundation
import Observation
@preconcurrency import Speech

/// Live English speech-to-text for conversation turns, on-device when the phone supports it.
/// (Pronunciation scoring does not use this; it uses the phoneme model on the backend.)
@MainActor
@Observable
final class SpeechTranscriber {
    private(set) var text = ""
    private(set) var isRunning = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        guard let recognizer, recognizer.isAvailable else { throw TranscriberError.unavailable }
        SpeechPlayer.shared.stop()
        AudioSessionConfigurator.configure()
        text = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let result else { return }
            let transcript = result.bestTranscription.formattedString
            Task { @MainActor in self?.text = transcript }
        }
        self.request = request
        isRunning = true
    }

    /// Stops listening and returns the transcript after the recognizer settles.
    func stop() async -> String {
        guard isRunning else { return text }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        isRunning = false
        try? await Task.sleep(nanoseconds: 700_000_000)
        task?.cancel()
        task = nil
        request = nil
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum TranscriberError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Nhận dạng giọng nói tiếng Anh chưa sẵn sàng trên máy này." }
    }
}
