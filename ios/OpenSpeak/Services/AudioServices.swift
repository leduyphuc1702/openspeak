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
        // Non-breaking space and hyphen: a licence name such as "CC BY-SA 4.0" must not be split across lines.
        let licence = license.replacingOccurrences(of: " ", with: "\u{00A0}").replacingOccurrences(of: "-", with: "\u{2011}")
        return "Giọng Mỹ thật: \(artist)\n\(licence) · Wikimedia\u{00A0}Commons"
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

    /// A US recording is on disk. Recordings of unknown accent, cached by older versions, do not count.
    static func has(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: audioURL(key).path) && storedCredit(key)?.accent == "en-US"
    }
    static func isMissing(_ key: String) -> Bool { FileManager.default.fileExists(atPath: missURL(key).path) }

    static func credit(for word: String) -> WordAudioCredit? {
        guard let key = key(word), has(key) else { return nil }
        return storedCredit(key)
    }

    private static func storedCredit(_ key: String) -> WordAudioCredit? {
        guard let data = try? Data(contentsOf: creditURL(key)) else { return nil }
        return try? JSONDecoder().decode(WordAudioCredit.self, from: data)
    }

    enum Fetched { case cached, missing, failed(retryAfter: TimeInterval?) }

    /// Downloads the recording. Only "Commons has none" is remembered on disk.
    static func fetch(_ key: String) async -> Fetched {
        guard let client = try? APIClient.current() else { return .failed(retryAfter: nil) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let found = try await client.wordAudio(key) else {
                try Data().write(to: missURL(key))
                return .missing
            }
            try found.data.write(to: audioURL(key))
            try JSONEncoder().encode(found.credit).write(to: creditURL(key))
            return .cached
        } catch APIError.busy(let retryAfter) {
            return .failed(retryAfter: retryAfter)
        } catch {
            return .failed(retryAfter: nil)
        }
    }

    /// Fetches recordings in the background, one at a time, so they are ready before the learner taps.
    static func prefetch(_ words: [String]) {
        Task { await WordAudioPrefetcher.shared.add(words.compactMap(key)) }
    }
}

/// Background downloads of word recordings. Playback never waits for them.
actor WordAudioPrefetcher {
    static let shared = WordAudioPrefetcher()
    private var queue: [String] = []
    private var running = false
    private var retryAt: [String: Date] = [:]
    private var pausedUntil = Date.distantPast

    func add(_ keys: [String]) {
        let now = Date()
        for key in keys where !queue.contains(key) && !WordAudioCache.has(key) && !WordAudioCache.isMissing(key)
            && (retryAt[key] ?? .distantPast) <= now {
            queue.append(key)
        }
        guard !running, !queue.isEmpty, now >= pausedUntil else { return }
        running = true
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty, Date() >= pausedUntil {
            let key = queue.removeFirst()
            if case .failed(let retryAfter) = await WordAudioCache.fetch(key) {
                retryAt[key] = Date().addingTimeInterval(120)
                if let retryAfter { pausedUntil = Date().addingTimeInterval(retryAfter) }
            }
        }
        if Date() < pausedUntil { queue.removeAll() }
        running = false
    }
}

/// Plays model pronunciations at once, always in the same standard US voice. Only a word card plays a
/// real person's recording from Wikimedia Commons (with its credit on screen); exercises never do,
/// because recordings differ in speaker and quality, and in a minimal pair the voice would give the
/// answer away. Bundled `phoneme_<ID>.(m4a|mp3|wav)` files take priority for isolated sounds.
@MainActor
final class SpeechPlayer {
    static let shared = SpeechPlayer()

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private let voice = SpeechPlayer.standardVoice()

    /// The best installed ordinary US voice. iOS also lists novelty voices (Bubbles, Whisper, Zarvox…)
    /// and old robotic ones (Fred, Ralph, the Eloquence set) under en-US; none of them is a model.
    /// Siri voices are left out too: other apps may get silence from them.
    static func standardVoice() -> AVSpeechSynthesisVoice? {
        let standard = AVSpeechSynthesisVoice.speechVoices().filter { v in
            v.language == "en-US"
                && !v.voiceTraits.contains(.isNoveltyVoice) && !v.voiceTraits.contains(.isPersonalVoice)
                && !v.identifier.contains("speech.synthesis") && !v.identifier.contains("eloquence")
                && !v.identifier.contains("siri")
        }
        let best = standard.max { a, b in
            if a.quality != b.quality { return a.quality.rawValue < b.quality.rawValue }
            if (a.name == "Samantha") != (b.name == "Samantha") { return b.name == "Samantha" }
            return a.identifier > b.identifier
        }
        return best ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    func speak(_ text: String, slow: Bool = false) {
        stop()
        tts(text, slow: slow)
    }

    /// A word card: the US recording if it is downloaded, otherwise the standard voice while it downloads.
    func speakRecording(_ word: String, slow: Bool = false) {
        stop()
        guard let key = WordAudioCache.key(word) else { return tts(word, slow: slow) }
        if WordAudioCache.has(key), playRecording(key, slow: slow) { return }
        tts(word, slow: slow)
        WordAudioCache.prefetch([key])
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
        if let fake = ProcessInfo.processInfo.environment["OPENSPEAK_FAKE_TAKE"] {
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
