@preconcurrency import AVFoundation
@preconcurrency import Speech

/// English speech-to-text for a recorded conversation turn, on-device when the phone supports it.
/// It only finds out which words were said; how they were pronounced is scored from the same
/// recording by the phoneme model on the backend.
enum SpeechTranscriber {
    static func authorize() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    /// The words in the recording. `hints` are phrases the learner is likely to say, which helps
    /// the recogniser pick the intended word when the pronunciation is off.
    static func transcribe(_ url: URL, hints: [String] = []) async throws -> String {
        #if DEBUG
        // The simulator's recogniser does not start; UI tests pass the words of the prepared take.
        if let fake = ProcessInfo.processInfo.environment["OPENSPEAK_FAKE_TRANSCRIPT"] { return fake }
        #endif
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            throw TranscriberError.unavailable
        }
        do {
            return try await run(recognizer, url: url, hints: hints, onDevice: recognizer.supportsOnDeviceRecognition)
        } catch TranscriberError.noSpeech {
            throw TranscriberError.noSpeech
        } catch {
            // The on-device model can be missing (not downloaded yet); Apple's server recogniser still works.
            guard recognizer.supportsOnDeviceRecognition else { throw error }
            return try await run(recognizer, url: url, hints: hints, onDevice: false)
        }
    }

    private static func run(_ recognizer: SFSpeechRecognizer, url: URL, hints: [String], onDevice: Bool) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = onDevice
        request.addsPunctuation = true
        request.contextualStrings = Array(hints.prefix(100))
        let once = Once()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                        once.run { text.isEmpty ? continuation.resume(throwing: TranscriberError.noSpeech)
                                                : continuation.resume(returning: text) }
                    } else if let error {
                        let nsError = error as NSError
                        // 1110: no speech detected; 203: nothing recognised.
                        let noSpeech = nsError.domain == "kAFAssistantErrorDomain" && [203, 1110].contains(nsError.code)
                        once.run { continuation.resume(throwing: noSpeech ? TranscriberError.noSpeech
                                                                          : TranscriberError.failed(error.localizedDescription)) }
                    }
                }
                once.task = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    once.run {
                        task.cancel()
                        continuation.resume(throwing: TranscriberError.failed("quá 30 giây"))
                    }
                }
            }
        } onCancel: {
            once.task?.cancel()
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        var task: SFSpeechRecognitionTask?

        func run(_ body: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            body()
        }
    }

    enum TranscriberError: LocalizedError {
        case unavailable, noSpeech, failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Nhận dạng giọng nói tiếng Anh chưa sẵn sàng trên máy này. Chạm bàn phím để gõ câu trả lời."
            case .noSpeech: return "Không nghe thấy câu nào trong bản ghi. Nói to, gần micro hơn rồi thử lại."
            case .failed(let reason): return "Không nhận dạng được câu vừa nói (\(reason)). Thử lại hoặc chạm bàn phím để gõ."
            }
        }
    }
}
