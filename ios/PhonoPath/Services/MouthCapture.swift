@preconcurrency import AVFoundation
import CoreImage
import Foundation
import Observation
import QuartzCore
import Vision

/// One measured video frame. `open` and `width` are lip sizes divided by the
/// distance between the eyes, so they do not depend on how close the face is.
struct LipFrame {
    let time: Double
    let open: Double
    let width: Double
    let jpeg: Data?
}

/// Front camera + Vision face landmarks. Measures the lips on every frame and,
/// while recording, keeps a small JPEG close-up of the mouth.
@MainActor
@Observable
final class MouthCapture {
    enum CaptureError: LocalizedError {
        case denied, noCamera

        var errorDescription: String? {
            switch self {
            case .denied: return "Ứng dụng cần quyền dùng camera. Bật trong Cài đặt > Quyền riêng tư > Camera."
            case .noCamera: return "Không tìm thấy camera trước."
            }
        }
    }

    let session = AVCaptureSession()
    private(set) var faceVisible = false
    private(set) var liveOpen: Double = 0
    private(set) var isRecording = false

    private let processor = LipFrameProcessor()
    private let queue = DispatchQueue(label: "phonopath.mouth-capture")
    private var configured = false
    private var frames: [LipFrame] = []
    private var recordingStart: CFTimeInterval = 0

    init() {
        processor.onFrame = { [weak self] measurement in
            Task { @MainActor in self?.receive(measurement) }
        }
    }

    func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw CaptureError.denied }
        if !configured { try configure() }
        let session = session
        queue.async { if !session.isRunning { session.startRunning() } }
    }

    func stop() {
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    func beginRecording(at start: CFTimeInterval = CACurrentMediaTime()) {
        frames = []
        recordingStart = start
        isRecording = true
        processor.keepImages = true
    }

    func endRecording() -> [LipFrame] {
        isRecording = false
        processor.keepImages = false
        return frames
    }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device) else { throw CaptureError.noCamera }
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(processor, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        if let connection = output.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = true }
        }
        session.commitConfiguration()
        configured = true
    }

    private func receive(_ m: LipFrameProcessor.Measurement) {
        faceVisible = m.faceFound
        guard m.faceFound else { return }
        liveOpen = m.open
        if isRecording {
            frames.append(LipFrame(time: m.time - recordingStart, open: m.open, width: m.width, jpeg: m.jpeg))
        }
    }
}

/// Runs off the main thread on the capture queue.
final class LipFrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Measurement: Sendable {
        let time: CFTimeInterval
        let faceFound: Bool
        let open: Double
        let width: Double
        let jpeg: Data?
    }

    var onFrame: (@Sendable (Measurement) -> Void)?
    var keepImages = false

    private let context = CIContext()
    private var lastFrame: CFTimeInterval = 0
    private let minInterval = 1.0 / 15

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastFrame >= minInterval, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = now

        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([request])
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        guard let face = request.results?.first, let landmarks = face.landmarks,
              let inner = landmarks.innerLips?.pointsInImage(imageSize: size),
              let outer = landmarks.outerLips?.pointsInImage(imageSize: size),
              let leftEye = landmarks.leftEye?.pointsInImage(imageSize: size),
              let rightEye = landmarks.rightEye?.pointsInImage(imageSize: size)
        else {
            onFrame?(Measurement(time: now, faceFound: false, open: 0, width: 0, jpeg: nil))
            return
        }

        let eyeDistance = hypot(Self.center(leftEye).x - Self.center(rightEye).x,
                                Self.center(leftEye).y - Self.center(rightEye).y)
        guard eyeDistance > 1 else { return }
        let innerBox = Self.bounds(inner), outerBox = Self.bounds(outer)
        let jpeg = keepImages ? mouthJPEG(pixels, around: outerBox) : nil
        onFrame?(Measurement(time: now, faceFound: true,
                             open: Double(innerBox.height / eyeDistance),
                             width: Double(outerBox.width / eyeDistance),
                             jpeg: jpeg))
    }

    /// A 256-px-wide close-up of the mouth and chin, enough to see teeth and tongue.
    private func mouthJPEG(_ pixels: CVPixelBuffer, around lips: CGRect) -> Data? {
        let image = CIImage(cvPixelBuffer: pixels)
        let crop = lips.insetBy(dx: -lips.width * 0.45, dy: -lips.height * 0.9).intersection(image.extent)
        guard crop.width > 8 else { return nil }
        let scale = 256 / crop.width
        let mouth = image.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return context.jpegRepresentation(of: mouth, colorSpace: colorSpace, options: [quality: 0.7])
    }

    private static func center(_ points: [CGPoint]) -> CGPoint {
        let n = CGFloat(max(points.count, 1))
        return CGPoint(x: points.map(\.x).reduce(0, +) / n, y: points.map(\.y).reduce(0, +) / n)
    }

    private static func bounds(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
