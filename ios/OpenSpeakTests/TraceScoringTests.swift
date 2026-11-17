import SwiftUI
import XCTest
@testable import OpenSpeak

@MainActor
final class TraceScoringTests: XCTestCase {
    private let side = TraceView.side

    private func mask(_ symbol: String) throws -> GlyphMask {
        try XCTUnwrap(GlyphMask(symbol: symbol, font: TraceView.font(for: symbol), side: side))
    }

    private func center(_ cell: Int, _ mask: GlyphMask) -> CGPoint {
        let size = side / CGFloat(mask.grid)
        return CGPoint(x: (CGFloat(cell % mask.grid) + 0.5) * size, y: (CGFloat(cell / mask.grid) + 0.5) * size)
    }

    /// A finger following one part of the glyph: down its middle, row by row.
    private func strokeAlong(_ component: [Int], _ mask: GlyphMask) -> [CGPoint] {
        let rows = Dictionary(grouping: component) { $0 / mask.grid }
        return rows.keys.sorted().map { row in
            let cols = rows[row]!.map { $0 % mask.grid }
            let mid = (cols.min()! + cols.max()!) / 2
            return center(row * mask.grid + mid, mask)
        }
    }

    private func ascii(_ mask: GlyphMask) -> String {
        (0..<mask.grid).map { row in
            String((0..<mask.grid).map { mask.ink[row * mask.grid + $0] ? "#" : "." })
        }.joined(separator: "\n")
    }

    func testMaskIsUprightAndSplitIntoParts() throws {
        let m = try mask("iː")
        print("iː mask:\n\(ascii(m))\ncomponents: \(m.components.map(\.count))")
        // i (stem + dot) and the two triangles of ː.
        XCTAssertGreaterThanOrEqual(m.components.count, 3)
        // Upright: the i's dot is above its stem.
        let leftmost = m.components.sorted { ($0.map { $0 % m.grid }.min()!) < ($1.map { $0 % m.grid }.min()!) }
        let dot = leftmost.min { $0.count < $1.count }!
        XCTAssertLessThan(dot.map { $0 / m.grid }.max()!, m.components.max { $0.count < $1.count }!.map { $0 / m.grid }.max()!)
    }

    /// The bug from the screenshot: one stroke over the "i" of /iː/ was accepted.
    func testOneStrokeOnPartOfTheSymbolFails() throws {
        let m = try mask("iː")
        let stem = try XCTUnwrap(m.components.max { $0.count < $1.count })
        let result = m.evaluate(strokes: [strokeAlong(stem, m)], side: side)
        // The rule before this fix: whole-symbol coverage >= 0.55 and precision >= 0.7.
        let oldRule = result.coverage >= 0.55 && result.precision >= 0.7
        print("iː one stroke on the stem: coverage \(result.coverage) precision \(result.precision) missed \(result.missedParts) old rule accepted: \(oldRule)")
        XCTAssertFalse(result.accepted)
        XCTAssertGreaterThan(result.missedParts, 0)
    }

    func testTracingEveryPartPasses() throws {
        for symbol in ["iː", "θ", "ð", "ʃ", "æ", "ɑː", "ŋ", "aɪ", "p"] {
            let m = try mask(symbol)
            let strokes = m.components.map { strokeAlong($0, m) }
            let result = m.evaluate(strokes: strokes, side: side)
            print("\(symbol): parts \(m.components.count) coverage \(result.coverage) precision \(result.precision)")
            XCTAssertTrue(result.accepted, "\(symbol) traced fully but rejected: \(result)")
        }
    }

    func testScribbleAcrossTheBoxFails() throws {
        let m = try mask("θ")
        var zigzag: [CGPoint] = []
        for i in 0...12 {
            zigzag.append(CGPoint(x: i % 2 == 0 ? 10 : side - 10, y: CGFloat(i) * side / 12))
        }
        let result = m.evaluate(strokes: [zigzag], side: side)
        print("θ zigzag: coverage \(result.coverage) precision \(result.precision)")
        XCTAssertFalse(result.accepted)
    }

    func testStrokeBesideTheSymbolFails() throws {
        let m = try mask("ʃ")
        let main = try XCTUnwrap(m.components.max { $0.count < $1.count })
        let shifted = strokeAlong(main, m).map { CGPoint(x: $0.x + 40, y: $0.y) }
        let result = m.evaluate(strokes: [shifted], side: side)
        print("ʃ shifted 40pt: coverage \(result.coverage) precision \(result.precision)")
        XCTAssertFalse(result.accepted)
    }
}
