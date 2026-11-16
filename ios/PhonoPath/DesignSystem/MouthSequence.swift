import AVFoundation
import Observation
import SwiftUI

/// One sound in a word or sentence, placed on the playback timeline.
struct MouthSegment: Identifiable, Hashable {
    enum Kind: Hashable { case inhale, phone, rest }

    let id: Int
    let kind: Kind
    let phoneme: Phoneme?
    let word: String
    var start: Double
    var end: Double
    let stressed: Bool
    let aspirated: Bool
    let wordFinal: Bool
    /// Pitch in semitones relative to the speaker's median; nil while voiceless.
    var pitch: Double?

    var duration: Double { end - start }
    var symbol: String { phoneme?.symbol ?? "" }
    var voiced: Bool { phoneme?.articulation.voiced ?? false }

    var air: AirCue {
        guard kind == .phone, let a = phoneme?.articulation else { return kind == .inhale ? .inhale : .none }
        switch a.manner {
        case "stop": return .hold
        case "affricate", "fricative": return .hiss
        case "nasal": return .nasal
        default: return .flow
        }
    }

    /// Stops build pressure, then release at the end of the segment.
    func air(at progress: Double) -> AirCue {
        if air == .hold && progress > 0.7 && !(wordFinal && !aspirated) { return .burst }
        if phoneme?.articulation.manner == "affricate" && progress < 0.4 { return .hold }
        return air
    }
}

/// Builds a timeline from an IPA transcription with typical English durations,
/// stress and an intonation contour. Real timings/pitch from the aligner replace these when available.
enum MouthSequenceBuilder {
    private static let inhaleLength = 0.55
    private static let restLength = 0.35
    private static let functionWords: Set<String> = Set("""
        a an the to of in on at for and or but nor so if as by from with into than that this these those \
        is am are was were be been being do does did have has had can could will would shall should may might must \
        i you he she it we they me him her us them my your his its our their
        """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
    private static let aliases: [String: String] = ["g": "ɡ", "ɾ": "t", "ɹ": "r", "ɐ": "ə", "ɜː": "ɝː", "i": "iː", "u": "uː"]

    static func build(text: String, ipa: String, intonation: String?, content: ContentStore) -> [MouthSegment] {
        let words = text.split(separator: " ").map { String($0).trimmingCharacters(in: .punctuationCharacters) }
        let bySymbol = Dictionary(content.phonemes.map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })

        struct Raw { let phoneme: Phoneme; let wordIndex: Int; let stressed: Bool; let syllableStart: Bool }
        var raws: [Raw] = []
        var wordIndex = 0
        var pendingStress = false
        var lastWasSpace = true
        for token in IPATokenizer.tokenize(ipa.replacingOccurrences(of: "‿", with: " ")) {
            if token.text == " " {
                if !lastWasSpace { wordIndex += 1 }
                lastWasSpace = true
                continue
            }
            lastWasSpace = false
            if token.text == "ˈ" { pendingStress = true; continue }
            if token.text == "ˌ" || token.text == "/" { continue }
            let symbol = aliases[token.text] ?? token.text
            guard let phoneme = bySymbol[symbol] else { continue }
            raws.append(Raw(phoneme: phoneme, wordIndex: wordIndex, stressed: pendingStress, syllableStart: pendingStress))
            if phoneme.category != .consonant { pendingStress = false }
        }
        // Monosyllabic content words carry stress even without a mark; function words stay weak.
        let wordCount = (raws.last?.wordIndex ?? 0) + 1
        var stressedVowel = Set<Int>()
        for w in 0..<wordCount {
            let idx = raws.indices.filter { raws[$0].wordIndex == w }
            let vowels = idx.filter { raws[$0].phoneme.category != .consonant }
            let isFunctionWord = w < words.count && functionWords.contains(words[w].lowercased())
            if let marked = idx.first(where: { raws[$0].stressed && raws[$0].phoneme.category != .consonant }) {
                stressedVowel.insert(marked)
            } else if vowels.count == 1 && (!isFunctionWord || wordCount == 1) {
                stressedVowel.insert(vowels[0])
            }
        }

        var segments: [MouthSegment] = []
        var t = 0.0
        segments.append(MouthSegment(id: 0, kind: .inhale, phoneme: nil, word: "", start: 0, end: inhaleLength,
                                     stressed: false, aspirated: false, wordFinal: false, pitch: nil))
        t = inhaleLength
        for (i, raw) in raws.enumerated() {
            let nextVowel = raws.indices.first(where: { $0 > i && raws[$0].phoneme.category != .consonant })
            let nextVowelStressed = nextVowel.map { stressedVowel.contains($0) && raws[$0].wordIndex == raw.wordIndex } ?? false
            let wordStart = i == 0 || raws[i - 1].wordIndex != raw.wordIndex
            let wordFinal = i == raws.count - 1 || raws[i + 1].wordIndex != raw.wordIndex
            let voicelessStop = ["P", "T", "K"].contains(raw.phoneme.id)
            let aspirated = voicelessStop && (wordStart || nextVowelStressed)
            let stressed = stressedVowel.contains(i)
            var d = baseDuration(raw.phoneme)
            if stressed { d *= 1.35 }
            if wordFinal && raw.wordIndex == wordCount - 1 { d *= 1.25 }
            segments.append(MouthSegment(id: segments.count, kind: .phone, phoneme: raw.phoneme,
                                         word: raw.wordIndex < words.count ? words[raw.wordIndex] : "",
                                         start: t, end: t + d, stressed: stressed, aspirated: aspirated,
                                         wordFinal: wordFinal, pitch: nil))
            t += d
        }
        segments.append(MouthSegment(id: segments.count, kind: .rest, phoneme: nil, word: "", start: t, end: t + restLength,
                                     stressed: false, aspirated: false, wordFinal: false, pitch: nil))
        applySyntheticPitch(&segments, intonation: intonation)
        return segments
    }

    static func baseDuration(_ p: Phoneme) -> Double {
        switch p.category {
        case .diphthong: return 0.24
        case .vowel: return p.symbol.contains("ː") ? 0.20 : 0.13
        case .consonant:
            switch p.articulation.manner {
            case "stop": return 0.08
            case "affricate": return 0.12
            case "fricative": return 0.11
            default: return 0.08
            }
        }
    }

    /// Declination, a peak on stressed vowels, and a final rise or fall.
    static func applySyntheticPitch(_ segments: inout [MouthSegment], intonation: String?) {
        let phones = segments.filter { $0.kind == .phone }
        guard let first = phones.first, let last = phones.last else { return }
        let lastStress = phones.last(where: \.stressed)?.start ?? first.start
        for i in segments.indices where segments[i].kind == .phone && segments[i].voiced {
            let s = segments[i]
            var p = 1.0 - 1.2 * (s.start - first.start) / max(last.end - first.start, 0.3)
            if s.stressed { p += 2.5 }
            if s.start >= lastStress {
                let u = (s.start - lastStress) / max(last.end - lastStress, 0.1)
                p += intonation == "rising" ? 5.0 * u : -4.0 * u
            }
            segments[i].pitch = p
        }
    }

    /// Replace estimated timings with forced-alignment times (when the phone count matches),
    /// keeping the inhale before and the rest after.
    static func applyAlignment(_ segments: inout [MouthSegment], phoneTimes: [(Double, Double)], lead: Double) {
        let idx = segments.indices.filter { segments[$0].kind == .phone }
        guard idx.count == phoneTimes.count, !idx.isEmpty else { return }
        for (k, i) in idx.enumerated() {
            segments[i].start = phoneTimes[k].0 + lead
            segments[i].end = max(phoneTimes[k].1 + lead, segments[i].start + 0.03)
        }
        if let first = idx.first, segments[0].kind == .inhale {
            segments[0].start = max(0, segments[first].start - inhaleLength)
            segments[0].end = segments[first].start
        }
        if let lastIdx = idx.last, segments[segments.count - 1].kind == .rest {
            segments[segments.count - 1].start = segments[lastIdx].end
            segments[segments.count - 1].end = segments[lastIdx].end + restLength
        }
    }

    /// Stretch estimated phone times onto the detected speech span of the reference audio.
    static func fit(_ segments: inout [MouthSegment], toSpeech span: ClosedRange<Double>, lead: Double) {
        let idx = segments.indices.filter { segments[$0].kind == .phone }
        guard let a = idx.first, let b = idx.last else { return }
        let s0 = segments[a].start, s1 = segments[b].end
        let k = (span.upperBound - span.lowerBound) / max(s1 - s0, 0.05)
        let times = idx.map { i in ((segments[i].start - s0) * k + span.lowerBound, (segments[i].end - s0) * k + span.lowerBound) }
        applyAlignment(&segments, phoneTimes: times, lead: lead)
    }
}

/// What the mouth looks like at a moment: blended pose plus breath and voice.
struct MouthFrame {
    let state: MouthState
    let segment: MouthSegment
    let progress: Double
    var air: AirCue { segment.air(at: progress) }
}

extension Array where Element == MouthSegment {
    var duration: Double { last?.end ?? 0 }

    func index(at t: Double) -> Int {
        firstIndex(where: { t < $0.end }) ?? (isEmpty ? 0 : count - 1)
    }

    /// Coarticulation: each sound starts from where the previous one ended.
    func frame(at t: Double) -> MouthFrame? {
        guard !isEmpty else { return nil }
        let i = index(at: t)
        let seg = self[i]
        let u = Swift.max(0, Swift.min(1, (t - seg.start) / Swift.max(seg.duration, 0.001)))
        let target = Self.pose(seg, progress: u)
        var state = target
        if i > 0 {
            let previous = Self.pose(self[i - 1], progress: 1)
            let transition = Swift.min(0.06, seg.duration * 0.4)
            let w = Swift.min(1, (t - seg.start) / Swift.max(transition, 0.001))
            state = previous.mixed(with: target, w * w * (3 - 2 * w))
        }
        return MouthFrame(state: state, segment: seg, progress: u)
    }

    private static func pose(_ seg: MouthSegment, progress u: Double) -> MouthState {
        guard let a = seg.phoneme?.articulation else {
            var rest = MouthState(.rest)
            if seg.kind == .inhale { rest.jaw = 0.15 }
            return rest
        }
        let start = MouthState(a.start)
        guard let end = a.end else { return start }
        let g = Swift.max(0, Swift.min(1, (u - 0.25) / 0.6))
        return start.mixed(with: MouthState(end), g * g * (3 - 2 * g))
    }
}

/// Plain-language instructions for the five things a learner must control.
struct MouthCues {
    let lips: String
    let teeth: String
    let tongue: String
    let breath: String
    let voice: String

    init(frame: MouthFrame, intonation: String?, isLastStress: Bool) {
        let seg = frame.segment
        guard let phoneme = seg.phoneme else {
            lips = "Môi thả lỏng, khép nhẹ"
            teeth = "Hai hàm hơi hé"
            tongue = "Lưỡi nằm thả lỏng"
            breath = seg.kind == .inhale ? "Hít nhẹ một hơi qua mũi, đủ cho cả câu" : "Kết thúc, thả lỏng"
            voice = seg.kind == .inhale ? "Chưa phát ra tiếng" : "Ngừng rung dây thanh"
            return
        }
        let a = phoneme.articulation
        let pose = (a.end != nil && frame.progress > 0.5) ? a.end! : a.start
        switch pose.lips {
        case "closed": lips = "Mím kín hai môi"
        case "rounded": lips = "Chu tròn môi ra trước"
        case "spread": lips = "Kéo dẹt môi sang hai bên (như cười)"
        case "labiodental": lips = "Môi dưới chạm nhẹ răng trên"
        default: lips = "Môi thả lỏng, tự nhiên"
        }
        if pose.lips == "labiodental" {
            teeth = "Răng trên tì nhẹ lên môi dưới"
        } else if pose.tip == "dental" {
            teeth = "Hé răng, đầu lưỡi kẹp nhẹ giữa hai hàm"
        } else if pose.jaw < 0.2 {
            teeth = "Hai hàm răng gần khít"
        } else if pose.jaw < 0.55 {
            teeth = "Hạ hàm vừa, răng hé khoảng một ngón tay"
        } else {
            teeth = "Hạ hàm sâu, mở rộng miệng"
        }
        var t: String
        switch pose.tip {
        case "dental": t = "Đầu lưỡi thò ra giữa hai răng"
        case "alveolar": t = pose.contact ? "Đầu lưỡi chạm lợi trên (sau răng cửa)" : "Đầu lưỡi gần lợi trên, không chạm"
        case "postalveolar": t = "Đầu lưỡi lùi sau lợi trên, thân lưỡi nâng"
        case "retroflex": t = "Đầu lưỡi cong lên, lùi về sau, không chạm"
        default:
            if pose.backContact {
                t = "Cuống lưỡi nâng chạm ngạc mềm"
            } else {
                let height = pose.tongueHeight > 0.7 ? "cao" : pose.tongueHeight > 0.4 ? "vừa" : "thấp"
                let place = pose.tongueFront > 0.65 ? "phía trước" : pose.tongueFront > 0.35 ? "ở giữa" : "lùi sau"
                t = "Đầu lưỡi tựa răng cửa dưới, thân lưỡi \(height), \(place)"
            }
        }
        tongue = t
        switch frame.air {
        case .hold: breath = "Chặn hơi lại sau chỗ khép"
        case .burst: breath = seg.aspirated ? "Bật hơi mạnh (đặt tay trước miệng thấy luồng gió)" : "Thả hơi ra nhẹ"
        case .hiss: breath = phoneme.id == "HH" ? "Hà hơi nhẹ ra như thở dài" : "Đẩy hơi liên tục qua khe hẹp (nghe tiếng xì)"
        case .nasal: breath = "Miệng chặn, hơi đi ra đường mũi"
        default:
            breath = seg.stressed ? "Đẩy hơi mạnh hơn: âm nhấn" : "Hơi đi êm, đều"
        }
        var v = a.voiced ? "Rung dây thanh (tay đặt ở cổ thấy rung)" : "Không rung, chỉ có hơi"
        if seg.stressed { v += " · nhấn: to, dài, cao hơn" }
        if isLastStress, a.voiced {
            v += intonation == "rising" ? " · giọng lên cao dần" : " · giọng đi xuống dần"
        }
        if seg.wordFinal && !a.voiced && a.manner == "stop" {
            v = "Không rung · giữ âm cuối, đừng nuốt mất"
        }
        voice = v
    }
}

/// Plays the mouth movements for a word or sentence in sync with model audio,
/// with slow motion, step-by-step and scrubbing.
@MainActor
@Observable
final class MouthPlayerModel {
    let text: String
    let intonation: String?
    private(set) var segments: [MouthSegment]
    private(set) var time: Double = 0
    private(set) var isPlaying = false
    private(set) var timing: String = "Ước lượng"
    var speed: Double = 0.5

    private var audioURL: URL?
    private var audioLead = 0.0
    private var player: AVAudioPlayer?
    private var audioStarted = false
    private var loop: Task<Void, Never>?
    private let renderer = ReferenceAudioRenderer()

    init(text: String, ipa: String, intonation: String?, content: ContentStore) {
        self.text = text
        self.intonation = intonation
        segments = MouthSequenceBuilder.build(text: text, ipa: ipa, intonation: intonation, content: content)
    }

    var duration: Double { segments.duration }
    var frame: MouthFrame? { segments.frame(at: time) }
    var phoneSegments: [MouthSegment] { segments.filter { $0.kind == .phone } }

    /// Renders model audio, then aligns it on the backend (real timings + pitch) or
    /// falls back to stretching estimates over the detected speech span.
    func prepare() async {
        guard audioURL == nil, let url = try? await renderer.render(text) else { return }
        audioURL = url
        audioLead = segments.first(where: { $0.kind == .inhale })?.duration ?? 0
        if let client = try? APIClient.current(),
           let aligned = try? await client.assess(text: text, audio: url, reference: nil, feedback: false) {
            let times = aligned.words.flatMap(\.phones).map { ($0.start, $0.end) }
            var updated = segments
            let lead = MouthPlayerModel.lead(for: times.first?.0 ?? 0)
            MouthSequenceBuilder.applyAlignment(&updated, phoneTimes: times, lead: lead)
            if updated != segments {
                applyPitch(aligned.pitchContour.user, to: &updated, lead: lead)
                segments = updated
                audioLead = lead
                timing = "Căn theo giọng mẫu"
                return
            }
        }
        if let span = MouthPlayerModel.speechSpan(url) {
            let lead = MouthPlayerModel.lead(for: span.lowerBound)
            MouthSequenceBuilder.fit(&segments, toSpeech: span, lead: lead)
            audioLead = lead
            timing = "Khớp theo độ dài giọng mẫu"
        }
    }

    /// Timeline time at which audio second 0 plays, leaving room for the inhale.
    private static func lead(for speechStart: Double) -> Double { max(0, 0.55 - speechStart) }

    private func applyPitch(_ contour: [[Double]], to segs: inout [MouthSegment], lead: Double) {
        let points = contour.compactMap { $0.count == 2 ? ($0[0] + lead, $0[1]) : nil }
        guard !points.isEmpty else { return }
        let median = points.map(\.1).sorted()[points.count / 2]
        for i in segs.indices where segs[i].kind == .phone {
            let inside = points.filter { $0.0 >= segs[i].start && $0.0 <= segs[i].end }.map(\.1)
            segs[i].pitch = inside.isEmpty ? nil : inside.reduce(0, +) / Double(inside.count) - median
        }
    }

    private static func speechSpan(_ url: URL) -> ClosedRange<Double>? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let data = buffer.floatChannelData?[0] else { return nil }
        let sr = file.processingFormat.sampleRate
        let hop = Int(sr * 0.01)
        let n = Int(buffer.frameLength) / max(hop, 1)
        guard n > 2 else { return nil }
        var energy = [Float](repeating: 0, count: n)
        for f in 0..<n {
            var sum: Float = 0
            for k in 0..<hop { let x = data[f * hop + k]; sum += x * x }
            energy[f] = (sum / Float(hop)).squareRoot()
        }
        let threshold = (energy.max() ?? 0) * 0.08
        guard let a = energy.firstIndex(where: { $0 > threshold }),
              let b = energy.lastIndex(where: { $0 > threshold }), b > a else { return nil }
        return Double(a) * 0.01...Double(b + 1) * 0.01
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        if time >= duration - 0.01 { time = 0 }
        isPlaying = true
        audioStarted = false
        loop?.cancel()
        var last = Date()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard let self else { return }
                let now = Date()
                self.advance(by: now.timeIntervalSince(last) * self.speed)
                last = now
                if !self.isPlaying { return }
            }
        }
    }

    func pause() {
        isPlaying = false
        loop?.cancel()
        player?.stop()
        audioStarted = false
    }

    func seek(_ t: Double) {
        pause()
        time = min(max(0, t), duration)
    }

    /// Jump to the middle of the next / previous sound and hold there.
    func step(_ direction: Int) {
        let phones = segments.indices.filter { segments[$0].kind == .phone }
        let current = segments.index(at: time)
        let target = direction > 0 ? phones.first(where: { $0 > current }) : phones.last(where: { $0 < current })
        guard let target else { return }
        let seg = segments[target]
        seek(seg.start + seg.duration * 0.5)
    }

    func select(_ segment: MouthSegment) {
        seek(segment.start + segment.duration * 0.5)
    }

    private func advance(by dt: Double) {
        time += dt
        if !audioStarted, speed >= 0.5, let url = audioURL, time >= audioLead {
            player = try? AVAudioPlayer(contentsOf: url)
            player?.enableRate = true
            player?.rate = Float(speed)
            player?.currentTime = time - audioLead
            player?.play()
            audioStarted = true
        }
        if time >= duration {
            time = duration
            pause()
        }
    }
}

struct WordMouthPlayer: View {
    @State private var model: MouthPlayerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(text: String, ipa: String, intonation: String? = nil, content: ContentStore) {
        _model = State(initialValue: MouthPlayerModel(text: text, ipa: ipa, intonation: intonation, content: content))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PitchStrip(model: model)
                .frame(height: 118)
            if let frame = model.frame {
                TimelineView(.animation(paused: !model.isPlaying && (reduceMotion || frame.air == .none))) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate
                    HStack(spacing: 10) {
                        MouthSideCanvas(state: frame.state, voiced: frame.segment.voiced,
                                        nasal: frame.segment.phoneme?.articulation.nasal ?? false,
                                        air: frame.air, phase: phase, annotated: true)
                            .aspectRatio(1, contentMode: .fit)
                        VStack(spacing: 8) {
                            Text(frame.segment.kind == .phone ? "/\(frame.segment.symbol)/" : (frame.segment.kind == .inhale ? "Hít hơi" : "Nghỉ"))
                                .font(.system(.title, design: .serif).bold())
                                .foregroundStyle(Theme.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                            Text(frame.segment.word).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            LipsFrontCanvas(state: frame.state)
                                .aspectRatio(0.8, contentMode: .fit)
                        }
                        .frame(maxWidth: 120)
                    }
                }
                CueList(cues: MouthCues(frame: frame, intonation: model.intonation,
                                        isLastStress: frame.segment.id == model.phoneSegments.last(where: \.stressed)?.id))
            }
            controls
            Text("Thời gian: \(model.timing). Kéo trên dải cao độ hoặc chạm vào một âm để dừng tại đó. Tốc độ 0.25× không phát tiếng.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task { await model.prepare() }
        .onDisappear { model.pause() }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button { model.step(-1) } label: {
                    Image(systemName: "backward.frame.fill").font(.title2).frame(width: 52, height: 52).contentShape(Rectangle())
                }
                .accessibilityLabel("Âm trước")
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                        .frame(width: 64, height: 64)
                        .background(Theme.primaryFill, in: Circle())
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(model.isPlaying ? "Tạm dừng" : "Phát")
                Button { model.step(1) } label: {
                    Image(systemName: "forward.frame.fill").font(.title2).frame(width: 52, height: 52).contentShape(Rectangle())
                }
                .accessibilityLabel("Âm sau")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.primary)
            .frame(maxWidth: .infinity)
            Picker("Tốc độ", selection: Binding(get: { model.speed }, set: { model.speed = $0; model.pause() })) {
                SwiftUI.Text("1×").tag(1.0)
                SwiftUI.Text("0.5×").tag(0.5)
                SwiftUI.Text("0.25×").tag(0.25)
            }
            .pickerStyle(.segmented)
        }
    }
}

/// Pitch line over time, the sounds underneath, and a playhead. Drag to scrub.
private struct PitchStrip: View {
    let model: MouthPlayerModel

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let total = max(model.duration, 0.1)
            let current = model.segments.index(at: model.time)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let plotH = size.height - 34
                    let pitches = model.segments.compactMap(\.pitch)
                    let lo = (pitches.min() ?? -3) - 1, hi = (pitches.max() ?? 3) + 1
                    func y(_ p: Double) -> CGFloat { CGFloat(plotH - (p - lo) / max(hi - lo, 1) * (plotH - 10) - 5) }
                    func x(_ t: Double) -> CGFloat { CGFloat(t / total) * size.width }
                    for seg in model.segments where seg.stressed {
                        context.fill(Path(CGRect(x: x(seg.start), y: 0, width: x(seg.end) - x(seg.start), height: plotH)),
                                     with: .color(Theme.accent.opacity(0.12)))
                    }
                    var line = Path()
                    var penDown = false
                    for seg in model.segments {
                        guard let p = seg.pitch else { penDown = false; continue }
                        let a = CGPoint(x: x(seg.start), y: y(p)), b = CGPoint(x: x(seg.end), y: y(p))
                        if penDown { line.addLine(to: a) } else { line.move(to: a) }
                        line.addLine(to: b)
                        penDown = true
                    }
                    context.stroke(line, with: .color(Theme.primary), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    let px = x(model.time)
                    context.stroke(Path { $0.move(to: CGPoint(x: px, y: 0)); $0.addLine(to: CGPoint(x: px, y: size.height)) },
                                   with: .color(Theme.accent), lineWidth: 2)
                }
                ForEach(model.segments.filter { $0.kind == .phone }) { seg in
                    let x0 = CGFloat(seg.start / total) * w, x1 = CGFloat(seg.end / total) * w
                    Button { model.select(seg) } label: {
                        Text(seg.symbol)
                            .font(.system(size: 14, weight: seg.stressed ? .heavy : .medium, design: .serif))
                            .frame(width: max(x1 - x0, 14), height: 26)
                            .background(seg.id == model.segments[current].id ? Theme.primaryFill : Theme.subtle,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(seg.id == model.segments[current].id ? .white : Theme.ink)
                    }
                    .buttonStyle(.plain)
                    .offset(x: x0, y: h - 28)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4).onChanged { g in
                model.seek(Double(g.location.x / max(w, 1)) * total)
            })
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityLabel("Cao độ giọng theo thời gian")
    }
}

private struct CueList: View {
    let cues: MouthCues

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("mouth", "Môi", cues.lips)
            row("square.split.2x1", "Răng", cues.teeth)
            row("scribble", "Lưỡi", cues.tongue)
            row("wind", "Hơi", cues.breath)
            row("waveform", "Giọng", cues.voice)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func row(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .frame(width: 26, height: 26)
                .background(Theme.primary.opacity(0.12), in: Circle())
                .foregroundStyle(Theme.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.bold()).foregroundStyle(.secondary)
                Text(text).font(.subheadline).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
