import AVFoundation
import Observation
import QuartzCore
import SwiftUI

@MainActor
@Observable
final class MouthCoachModel {
    enum Phase {
        case preparing
        case ready
        case recording
        case analyzing
        case result(Assessment, ArticulationFeedback)
        case failed(String)
    }

    let item: PracticeItem
    let capture = MouthCapture()
    let recorder = AudioRecorder()
    private(set) var phase: Phase = .preparing
    private(set) var thumbnails: [Int: Data] = [:]

    init(item: PracticeItem) {
        self.item = item
    }

    func prepare() async {
        do {
            try await capture.start()
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func toggle(content: ContentStore, progress: ProgressStore) async {
        if recorder.isRecording {
            await finish(content: content, progress: progress)
            return
        }
        guard await recorder.requestPermission() else {
            phase = .failed("Ứng dụng cần quyền dùng micro.")
            return
        }
        do {
            capture.beginRecording(at: CACurrentMediaTime())
            try recorder.start()
            phase = .recording
            Haptics.tap()
        } catch {
            _ = capture.endRecording()
            phase = .failed(error.localizedDescription)
        }
    }

    func retry() {
        thumbnails = [:]
        phase = .ready
    }

    func shutdown() {
        if recorder.isRecording { recorder.stop() }
        capture.stop()
    }

    private func finish(content: ContentStore, progress: ProgressStore) async {
        let frames = capture.endRecording()
        guard let audio = recorder.stop() else { return }
        phase = .analyzing
        do {
            let client = try APIClient.current()
            let assessment = try await client.assess(text: item.text, audio: audio, reference: nil, feedback: false)
            progress.record(assessment, key: item.key)
            let (samples, images) = Self.pickSamples(assessment: assessment, frames: frames, content: content)
            guard !samples.isEmpty else {
                phase = .failed("Không thấy rõ khuôn mặt khi nói. Giữ điện thoại ngang mặt, đủ sáng và thử lại.")
                return
            }
            let feedback = try await client.articulationFeedback(text: item.text, samples: samples, frames: images)
            thumbnails = images
            phase = .result(assessment, feedback)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Pairs each scored sound with the video frame closest to its middle, then
    /// chooses up to 8 close-ups: sounds the lips show best and sounds scored low.
    static func pickSamples(assessment: Assessment, frames: [LipFrame], content: ContentStore) -> ([LipSample], [Int: Data]) {
        guard !frames.isEmpty else { return ([], [:]) }
        var samples: [LipSample] = []
        var candidates: [(index: Int, priority: Int, jpeg: Data)] = []
        for word in assessment.words {
            for phone in word.phones {
                guard let id = phone.id, phone.status != .missing else { continue }
                let mid = (phone.start + phone.end) / 2
                guard let frame = frames.min(by: { abs($0.time - mid) < abs($1.time - mid) }),
                      abs(frame.time - mid) < 0.15 else { continue }
                let index = samples.count
                samples.append(LipSample(index: index, word: word.word, phoneId: id, time: mid,
                                         open: frame.open, width: frame.width))
                guard let jpeg = frame.jpeg, let phoneme = content.phoneme(id) else { continue }
                let visible = phoneme.articulation.start.lips != "neutral" || phoneme.articulation.start.tip == "dental"
                let weak = (phone.score ?? 100) < 70
                if visible || weak {
                    candidates.append((index, (weak ? 2 : 0) + (visible ? 1 : 0), jpeg))
                }
            }
        }
        let chosen = candidates.sorted { $0.priority > $1.priority }.prefix(8)
        return (samples, Dictionary(uniqueKeysWithValues: chosen.map { ($0.index, $0.jpeg) }))
    }
}

/// Record yourself saying the text; the app measures your lips frame by frame and
/// (with a vision LLM configured) a coach looks at close-ups of your mouth.
struct MouthCoachView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ContentStore.self) private var content
    @Environment(ProgressStore.self) private var progress
    @State private var model: MouthCoachModel

    init(item: PracticeItem) {
        _model = State(initialValue: MouthCoachModel(item: item))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    switch model.phase {
                    case .result(let assessment, let feedback):
                        MouthFeedbackView(assessment: assessment, feedback: feedback, thumbnails: model.thumbnails)
                        Button("Quay lại lần nữa") { model.retry() }
                            .buttonStyle(PrimaryButtonStyle())
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.bad)
                            .card()
                        Button("Thử lại") { model.retry() }
                            .buttonStyle(SecondaryButtonStyle())
                    default:
                        recorderPanel
                    }
                }
                .padding(20)
            }
            .screenBackground()
            .inlineNavigationTitle("Quay khẩu hình")
            .closeToolbar()
        }
        .task { await model.prepare() }
        .onDisappear { model.shutdown() }
    }

    private var recorderPanel: some View {
        VStack(spacing: 16) {
            ZStack(alignment: .bottom) {
                CameraPreview(session: model.capture.session)
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(model.recorder.isRecording ? Theme.bad : .clear, lineWidth: 4)
                    )
                HStack {
                    Label(model.capture.faceVisible ? "Đã thấy miệng" : "Đưa mặt vào khung",
                          systemImage: model.capture.faceVisible ? "face.smiling" : "viewfinder")
                    Spacer()
                    if model.capture.faceVisible {
                        Text("Độ mở \(String(format: "%.2f", model.capture.liveOpen))")
                            .monospacedDigit()
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(12)
            }

            VStack(spacing: 6) {
                Text(model.item.text).font(.title2.bold()).multilineTextAlignment(.center)
                if let ipa = model.item.connectedIPA ?? model.item.ipa {
                    Text("/\(ipa)/").font(.system(.body, design: .serif)).foregroundStyle(Theme.primary)
                }
            }

            if let focus = content.phoneme(model.item.focusPhone) {
                HStack(spacing: 12) {
                    MouthDiagramView(articulation: focus.articulation, compact: true)
                        .frame(width: 110)
                    Text("Soi gương: so khẩu hình của bạn với hình mẫu /\(focus.symbol)/ khi nói.")
                        .font(.subheadline)
                }
                .card()
            }

            if case .analyzing = model.phase {
                ProgressView("AI đang xem khẩu hình…").padding()
            } else {
                MicButton(isRecording: model.recorder.isRecording, level: model.recorder.level) {
                    Task { await model.toggle(content: content, progress: progress) }
                }
                .disabled(!model.capture.faceVisible && !model.recorder.isRecording)
                Text(model.recorder.isRecording ? "Đang quay… chạm để dừng" : "Nhìn thẳng camera, nói rõ và chậm")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MouthFeedbackView: View {
    let assessment: Assessment
    let feedback: ArticulationFeedback
    let thumbnails: [Int: Data]
    @Environment(ContentStore.self) private var content

    private var advice: [Int: ArticulationFeedback.Coach.Frame] {
        Dictionary((feedback.coach?.frames ?? []).map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Problems first, then frames the coach looked at, then a few that were fine.
    private var shown: [ArticulationFeedback.Finding] {
        let fixes = feedback.findings.filter { $0.status != "ok" || advice[$0.index]?.ok == false }
        let withImages = feedback.findings.filter { thumbnails[$0.index] != nil && !fixes.contains($0) }
        return fixes + withImages
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                ScoreRing(score: assessment.scores.pronunciation, size: 88)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Khẩu hình").font(.headline)
                    let fixes = feedback.findings.filter { $0.status == "fix" }.count
                    Text(fixes == 0 ? "Môi của bạn khớp với các âm đã đo." : "\(fixes) chỗ cần chỉnh khẩu hình môi.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .card()

            if let summary = feedback.coach?.summary, !summary.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Huấn luyện viên AI", systemImage: "sparkles").font(.headline)
                    Text(summary)
                }
                .card()
            }

            ForEach(shown, id: \.index) { finding in
                FindingRow(finding: finding, advice: advice[finding.index],
                           image: thumbnails[finding.index], phoneme: content.phoneme(finding.phoneId))
            }
            if shown.isEmpty {
                Label("Không có chỗ nào cần sửa. Tuyệt vời!", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.good)
                    .card()
            }
        }
    }
}

private struct FindingRow: View {
    let finding: ArticulationFeedback.Finding
    let advice: ArticulationFeedback.Coach.Frame?
    let image: Data?
    let phoneme: Phoneme?

    private var isProblem: Bool { finding.status == "fix" || advice?.ok == false }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let image, let picture = Image(jpeg: image) {
                picture
                    .resizable()
                    .scaledToFill()
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if let phoneme {
                MouthDiagramView(articulation: phoneme.articulation, compact: true)
                    .frame(width: 84)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(finding.word).font(.headline)
                    if let phoneme {
                        Text("/\(phoneme.symbol)/").font(.system(.headline, design: .serif)).foregroundStyle(Theme.primary)
                    }
                    Spacer()
                    Image(systemName: isProblem ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(isProblem ? Theme.ok : Theme.good)
                }
                Text(finding.message).font(.subheadline)
                if let advice, !advice.advice.isEmpty {
                    Text(advice.advice).font(.subheadline).foregroundStyle(Theme.primary)
                }
            }
        }
        .card()
    }
}

extension Image {
    init?(jpeg data: Data) {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        self.init(uiImage: image)
        #else
        guard let image = NSImage(data: data) else { return nil }
        self.init(nsImage: image)
        #endif
    }
}

#if os(iOS)
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
#else
struct CameraPreview: View {
    let session: AVCaptureSession
    var body: some View { Color.black }
}
#endif
