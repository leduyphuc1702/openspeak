import AVFoundation
import Foundation
import Observation

enum AudioSessionConfigurator {
    static func configure() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? session.setActive(true)
        #endif
    }
}

struct WordAudioCredit: Codable, Hashable {
    let artist: String
    let license: String
    let source: String
    let accent: String

    var line: String {
        let who = accent == "en-US" ? "Giọng Mỹ thật" : "Giọng người thật"
        // Non-breaking space and hyphen: a licence name such as "CC BY-SA 4.0" must not be split across lines.
        let licence = license.replacingOccurrences(of: " ", with: "\u{00A0}").replacingOccurrences(of: "-", with: "\u{2011}")
        return "\(who): \(artist)\n\(licence) · Wikimedia\u{00A0}Commons"
    }
}

/// Human word recordings fetched once through the backend and kept in Caches.
enum WordAudioCache {
    private static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("word_audio", isDirectory: true)

    /// Lower-cased single word, or nil for phrases and sentences.
    static func key(_ text: String) -> String? {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return word.range(of: "^[a-z][a-z'-]{0,39}$", options: .regularExpression) == nil ? nil : word
    }

    static func audioURL(_ key: String) -> URL { directory.appendingPathComponent("\(key).wav") }
    private static func creditURL(_ key: String) -> URL { directory.appendingPathComponent("\(key).json") }
    private static func missURL(_ key: String) -> URL { directory.appendingPathComponent("\(key).miss") }

    static func has(_ key: String) -> Bool { FileManager.default.fileExists(atPath: audioURL(key).path) }
    static func isMissing(_ key: String) -> Bool { FileManager.default.fileExists(atPath: missURL(key).path) }

    static func credit(for word: String) -> WordAudioCredit? {
        guard let key = key(word), let data = try? Data(contentsOf: creditURL(key)) else { return nil }
        return try? JSONDecoder().decode(WordAudioCredit.self, from: data)
    }

    /// Downloads the recording; true when one is now cached. Network errors are not remembered.
    static func fetch(_ key: String) async -> Bool {
        guard let client = try? APIClient.current() else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let found = try await client.wordAudio(key) else {
                try Data().write(to: missURL(key))
                return false
            }
            try found.data.write(to: audioURL(key))
            try JSONEncoder().encode(found.credit).write(to: creditURL(key))
            return true
        } catch {
            return false
        }
    }
}

/// Plays model pronunciations. Single words use a real person's recording from Wikimedia Commons
/// when the backend can find one; bundled `phoneme_<ID>.(m4a|mp3|wav)` files take priority for
/// isolated sounds; everything else falls back to on-device TTS.
@MainActor
final class SpeechPlayer {
    static let shared = SpeechPlayer()

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private let voice = AVSpeechSynthesisVoice(language: "en-US")
    private var pending: UUID?

    func speak(_ text: String, slow: Bool = false) {
        stop()
        guard let key = WordAudioCache.key(text) else { return tts(text, slow: slow) }
        if WordAudioCache.has(key), playRecording(key, slow: slow) { return }
        if WordAudioCache.isMissing(key) { return tts(text, slow: slow) }
        let token = UUID()
        pending = token
        Task {
            let ok = await WordAudioCache.fetch(key)
            guard pending == token else { return }
            pending = nil
            if !(ok && playRecording(key, slow: slow)) { tts(text, slow: slow) }
        }
    }

    private func tts(_ text: String, slow: Bool) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = slow ? 0.32 : 0.45
        synthesizer.speak(utterance)
    }

    private func playRecording(_ key: String, slow: Bool) -> Bool {
        guard let player = try? AVAudioPlayer(contentsOf: WordAudioCache.audioURL(key)) else { return false }
        player.enableRate = true
        player.rate = slow ? 0.6 : 1
        player.prepareToPlay()
        self.player = player
        return player.play()
    }

    func speak(phoneme: Phoneme) {
        stop()
        for ext in ["m4a", "mp3", "wav"] {
            if let url = Bundle.main.url(forResource: "phoneme_\(phoneme.id)", withExtension: ext) {
                player = try? AVAudioPlayer(contentsOf: url)
                player?.play()
                return
            }
        }
        let text = NSMutableAttributedString(string: phoneme.symbol)
        text.addAttribute(
            NSAttributedString.Key(rawValue: AVSpeechSynthesisIPANotationAttribute),
            value: phoneme.speakIPA,
            range: NSRange(location: 0, length: text.length)
        )
        let utterance = AVSpeechUtterance(attributedString: text)
        utterance.voice = voice
        utterance.rate = 0.35
        synthesizer.speak(utterance)
    }

    func play(url: URL) {
        stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }

    func stop() {
        pending = nil
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
    }
}

/// Records 16 kHz mono 16-bit WAV, the format the acoustic model expects.
@MainActor
@Observable
final class AudioRecorder {
    private(set) var isRecording = false
    private(set) var level: Float = 0
    private(set) var lastRecording: URL?

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        SpeechPlayer.shared.stop()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw RecorderError.couldNotStart }
        self.recorder = recorder
        isRecording = true
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateLevel() }
        }
    }

    @discardableResult
    func stop() -> URL? {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        isRecording = false
        level = 0
        lastRecording = recorder?.url
        recorder = nil
        #if DEBUG
        // UI tests on a Mac without a speaker: substitute a prepared take.
        if let fake = ProcessInfo.processInfo.environment["PHONOPATH_FAKE_TAKE"] {
            lastRecording = URL(fileURLWithPath: fake)
        }
        #endif
        return lastRecording
    }

    private func updateLevel() {
        guard let recorder else { return }
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        level = max(0, min(1, (db + 50) / 50))
    }

    enum RecorderError: LocalizedError {
        case couldNotStart
        var errorDescription: String? { "Không thể bắt đầu ghi âm." }
    }
}

/// Renders the target sentence with on-device TTS to a WAV file. The backend
/// compares the learner's pitch contour against it (DTW).
@MainActor
final class ReferenceAudioRenderer {
    private let synthesizer = AVSpeechSynthesizer()
    private var cache: [String: URL] = [:]

    func render(_ text: String) async throws -> URL {
        if let cached = cache[text], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ref-\(UUID().uuidString).wav")
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.45

        let result: URL = try await withCheckedThrowingContinuation { continuation in
            var file: AVAudioFile?
            var finished = false
            synthesizer.write(utterance) { buffer in
                guard !finished, let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    finished = true
                    file = nil // closes and flushes the file
                    continuation.resume(returning: url)
                    return
                }
                do {
                    if file == nil {
                        file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                               commonFormat: pcm.format.commonFormat,
                                               interleaved: pcm.format.isInterleaved)
                    }
                    try file?.write(from: pcm)
                } catch {
                    finished = true
                    file = nil
                    continuation.resume(throwing: error)
                }
            }
        }
        cache[text] = result
        return result
    }
}
