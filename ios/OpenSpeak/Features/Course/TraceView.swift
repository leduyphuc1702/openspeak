import SwiftUI

/// The symbol rasterised to a coarse grid, used to check a tracing.
struct GlyphMask {
    let grid: Int
    let ink: [Bool]
    let near: [Bool]   // ink grown by a couple of cells: strokes here count as on the letter
    /// Separate parts of the symbol (the stem and dot of i, each triangle of ː), as ink cell indices.
    let components: [[Int]]

    struct Result: CustomStringConvertible {
        let coverage: Double
        let precision: Double
        /// Parts of the symbol the drawing mostly left out.
        let missedParts: Int

        var accepted: Bool { missedParts == 0 && coverage >= GlyphMask.minCoverage && precision >= GlyphMask.minPrecision }
        var description: String { "coverage \(coverage), precision \(precision), missed parts \(missedParts)" }
    }

    static let minCoverage = 0.65
    static let minPrecision = 0.75
    static let minPartCoverage = 0.5

    @MainActor
    init?(symbol: String, font: Font, side: CGFloat, grid: Int = 52) {
        let renderer = ImageRenderer(content:
            Text(symbol).font(font).foregroundStyle(.black).frame(width: side, height: side)
        )
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        var pixels = [UInt8](repeating: 255, count: grid * grid)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: grid, height: grid, bitsPerComponent: 8,
                                          bytesPerRow: grid, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: grid, height: grid))
            context.draw(image, in: CGRect(x: 0, y: 0, width: grid, height: grid))
            return true
        }
        guard drawn else { return nil }
        let ink = pixels.map { $0 < 140 }
        guard ink.contains(true) else { return nil }
        var near = ink
        for row in 0..<grid {
            for col in 0..<grid where ink[row * grid + col] {
                for dr in -2...2 {
                    for dc in -2...2 {
                        let r = row + dr, c = col + dc
                        if r >= 0, r < grid, c >= 0, c < grid { near[r * grid + c] = true }
                    }
                }
            }
        }
        self.grid = grid
        self.ink = ink
        self.near = near
        self.components = Self.parts(of: ink, grid: grid)
    }

    /// 8-connected groups of ink cells, without specks of one or two cells.
    private static func parts(of ink: [Bool], grid: Int) -> [[Int]] {
        var seen = [Bool](repeating: false, count: ink.count)
        var result: [[Int]] = []
        for start in ink.indices where ink[start] && !seen[start] {
            var stack = [start], part: [Int] = []
            seen[start] = true
            while let cell = stack.popLast() {
                part.append(cell)
                let row = cell / grid, col = cell % grid
                for dr in -1...1 {
                    for dc in -1...1 {
                        let r = row + dr, c = col + dc
                        guard r >= 0, r < grid, c >= 0, c < grid else { continue }
                        let next = r * grid + c
                        if ink[next] && !seen[next] {
                            seen[next] = true
                            stack.append(next)
                        }
                    }
                }
            }
            if part.count > 2 { result.append(part) }
        }
        return result
    }

    /// Accepts a tracing only if it covers enough of the whole symbol, stays on it, and goes over
    /// every part, so a stroke over the i of /iː/ alone is not enough.
    func evaluate(strokes: [[CGPoint]], side: CGFloat) -> Result {
        let (covered, onLetter, total) = cells(strokes: strokes, side: side)
        let inkCells = ink.indices.filter { ink[$0] }
        let coverage = Double(inkCells.filter(covered.contains).count) / Double(max(inkCells.count, 1))
        let missed = components.filter { part in
            Double(part.filter(covered.contains).count) / Double(part.count) < Self.minPartCoverage
        }.count
        return Result(coverage: coverage, precision: Double(onLetter) / Double(max(total, 1)), missedParts: missed)
    }

    /// Cells under the finger (a stroke is about three cells wide), and how many drawn points lie on the letter.
    private func cells(strokes: [[CGPoint]], side: CGFloat) -> (covered: Set<Int>, onLetter: Int, total: Int) {
        let cell = side / CGFloat(grid)
        var covered = Set<Int>()
        var onLetter = 0, total = 0
        for stroke in strokes {
            for point in densified(stroke, step: cell / 2) {
                let col = Int(point.x / cell), row = Int(point.y / cell)
                total += 1
                guard row >= 0, row < grid, col >= 0, col < grid else { continue }
                if near[row * grid + col] { onLetter += 1 }
                for dr in -1...1 {
                    for dc in -1...1 {
                        let r = row + dr, c = col + dc
                        if r >= 0, r < grid, c >= 0, c < grid { covered.insert(r * grid + c) }
                    }
                }
            }
        }
        return (covered, onLetter, total)
    }

    private func densified(_ stroke: [CGPoint], step: CGFloat) -> [CGPoint] {
        guard var previous = stroke.first else { return [] }
        var points = [previous]
        for point in stroke.dropFirst() {
            let distance = hypot(point.x - previous.x, point.y - previous.y)
            let count = max(Int(distance / step), 1)
            for i in 1...count {
                let t = CGFloat(i) / CGFloat(count)
                points.append(CGPoint(x: previous.x + (point.x - previous.x) * t, y: previous.y + (point.y - previous.y) * t))
            }
            previous = point
        }
        return points
    }
}

/// Trace the faint symbol with a finger, like tracing letters in a kindergarten workbook.
struct TraceView: View {
    let symbol: String
    let onSuccess: () -> Void

    static let side: CGFloat = 260
    static func font(for symbol: String) -> Font {
        .system(size: symbol.count > 1 ? 150 : 200, weight: .regular, design: .serif)
    }
    private var font: Font { Self.font(for: symbol) }

    @State private var strokes: [[CGPoint]] = []
    @State private var drawing = false
    @State private var mask: GlyphMask?
    @State private var maskFailed = false
    @State private var message = "Dùng ngón tay tô theo ký hiệu."
    @State private var passed = false

    var body: some View {
        LessonStepLayout {
            ZStack {
                Text(symbol)
                    .font(font)
                    .foregroundStyle(Theme.primary.opacity(0.14))
                Text(symbol)
                    .font(font)
                    .foregroundStyle(.clear)
                    .overlay(
                        Text(symbol).font(font)
                            .foregroundStyle(Theme.primary.opacity(0.35))
                            .mask(StripeMask())
                    )
                Canvas { context, _ in
                    for stroke in strokes where stroke.count > 0 {
                        var path = Path()
                        path.addLines(stroke.count == 1 ? [stroke[0], stroke[0]] : stroke)
                        context.stroke(path, with: .color(passed ? Theme.good : Theme.accent),
                                       style: StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .frame(width: Self.side, height: Self.side)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !passed else { return }
                        if drawing {
                            strokes[strokes.count - 1].append(value.location)
                        } else {
                            strokes.append([value.location])
                            drawing = true
                        }
                    }
                    .onEnded { _ in
                        drawing = false
                        evaluate()
                    }
            )

            Text(message)
                .font(.subheadline)
                .foregroundStyle(passed ? Theme.good : .secondary)
                .multilineTextAlignment(.center)
        } actions: {
            HStack(spacing: 12) {
                Button("Tô lại") {
                    strokes = []
                    passed = false
                    message = "Dùng ngón tay tô theo ký hiệu."
                }
                .buttonStyle(SecondaryButtonStyle())
                Button("Tiếp tục", action: onSuccess)
                    .buttonStyle(PrimaryButtonStyle(color: passed ? Theme.good : Theme.primary))
                    .disabled(!(passed || maskFailed))
                    .opacity(passed || maskFailed ? 1 : 0.5)
            }
        }
        .onAppear {
            mask = GlyphMask(symbol: symbol, font: font, side: Self.side)
            maskFailed = mask == nil
        }
    }

    private func evaluate() {
        guard let mask else {
            message = "Máy này không tạo được mẫu để chấm nét vẽ. Bấm Tiếp tục để sang bước sau."
            return
        }
        let result = mask.evaluate(strokes: strokes, side: Self.side)
        var accepted = result.accepted
        #if DEBUG
        // UI tests cannot draw a letter accurately; with this set, the second stroke passes.
        if ProcessInfo.processInfo.environment["OPENSPEAK_EASY_TRACE"] != nil, strokes.count >= 2 { accepted = true }
        #endif
        if accepted {
            passed = true
            message = "Giỏi lắm! Bạn đã viết được /\(symbol)/."
            Haptics.result(success: true)
            SpeechPlayer.shared.speak("Great")
        } else if result.precision < GlyphMask.minPrecision {
            message = "Nét vẽ đang lệch ra ngoài. Tô lại sát theo chữ nhé."
        } else if result.missedParts > 0 {
            message = "Đã tô được \(Int(result.coverage * 100))%. Còn \(result.missedParts) phần của ký hiệu chưa tô (kể cả dấu chấm, dấu ː)."
        } else {
            message = "Đã tô được \(Int(result.coverage * 100))%. Tô kín hơn theo các nét."
        }
    }
}

/// Diagonal stripes, so the guide letter looks like a dotted workbook letter.
private struct StripeMask: View {
    var body: some View {
        Canvas { context, size in
            var x: CGFloat = -size.height
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(path, with: .color(.black), lineWidth: 3)
                x += 9
            }
        }
    }
}
