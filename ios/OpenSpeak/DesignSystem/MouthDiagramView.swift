import SwiftUI

/// Numeric form of an `ArticulationPose`, so poses can be blended and animated.
struct MouthState: Equatable {
    var round: Double
    var spread: Double
    var closed: Double
    var labiodental: Double
    var jaw: Double
    var tongueHeight: Double
    var tongueFront: Double
    var tip: CGPoint
    var tipContact: Double
    var backContact: Double

    init(_ pose: ArticulationPose) {
        round = pose.lips == "rounded" ? 1 : 0
        spread = pose.lips == "spread" ? 1 : 0
        closed = pose.lips == "closed" ? 1 : 0
        labiodental = pose.lips == "labiodental" ? 1 : 0
        jaw = pose.jaw
        tongueHeight = pose.tongueHeight
        tongueFront = pose.tongueFront
        // For /p b m/ the data marks the lips as the contact; the tongue tip is only in contact when raised.
        tipContact = pose.contact && pose.tip != "rest" ? 1 : 0
        backContact = pose.backContact ? 1 : 0
        // Unit coordinates of the side view; the contact points lie on the roof of the mouth.
        let gap = pose.contact ? 0.0 : 0.03
        switch pose.tip {
        case "dental": tip = CGPoint(x: 0.150, y: 0.468 + pose.jaw * 0.06)
        case "alveolar": tip = CGPoint(x: 0.258, y: 0.378 + gap)
        case "postalveolar": tip = CGPoint(x: 0.315, y: 0.352 + gap)
        case "retroflex": tip = CGPoint(x: 0.365, y: 0.340 + gap)
        default: tip = CGPoint(x: 0.240, y: 0.522 + pose.jaw * 0.12)
        }
    }

    func mixed(with other: MouthState, _ t: Double) -> MouthState {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        var result = self
        result.round = mix(round, other.round)
        result.spread = mix(spread, other.spread)
        result.closed = mix(closed, other.closed)
        result.labiodental = mix(labiodental, other.labiodental)
        result.jaw = mix(jaw, other.jaw)
        result.tongueHeight = mix(tongueHeight, other.tongueHeight)
        result.tongueFront = mix(tongueFront, other.tongueFront)
        result.tip = CGPoint(x: mix(tip.x, other.tip.x), y: mix(tip.y, other.tip.y))
        result.tipContact = mix(tipContact, other.tipContact)
        result.backContact = mix(backContact, other.backContact)
        return result
    }

    /// The closure of a stop let go: lips part, the tongue drops away from the roof.
    func released(_ amount: Double) -> MouthState {
        var result = self
        result.closed = closed * (1 - amount)
        result.tip.y += tipContact * amount * 0.035
        result.tipContact = tipContact * (1 - amount)
        result.backContact = backContact * (1 - amount)
        return result
    }
}

extension MouthState: Animatable {
    var animatableData: MouthVector {
        get { MouthVector(values: [round, spread, closed, labiodental, jaw, tongueHeight, tongueFront,
                                   tip.x, tip.y, tipContact, backContact]) }
        set {
            let v = newValue.values
            guard v.count == 11 else { return }
            round = v[0]; spread = v[1]; closed = v[2]; labiodental = v[3]; jaw = v[4]
            tongueHeight = v[5]; tongueFront = v[6]; tip = CGPoint(x: v[7], y: v[8])
            tipContact = v[9]; backContact = v[10]
        }
    }
}

struct MouthVector: VectorArithmetic {
    var values: [Double]

    static var zero: MouthVector { MouthVector(values: Array(repeating: 0, count: 11)) }

    private static func combine(_ a: MouthVector, _ b: MouthVector, _ op: (Double, Double) -> Double) -> MouthVector {
        let x = a.values.count == 11 ? a.values : zero.values
        let y = b.values.count == 11 ? b.values : zero.values
        return MouthVector(values: zip(x, y).map(op))
    }

    static func + (a: MouthVector, b: MouthVector) -> MouthVector { combine(a, b, +) }
    static func - (a: MouthVector, b: MouthVector) -> MouthVector { combine(a, b, -) }
    mutating func scale(by factor: Double) { values = values.map { $0 * factor } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}

/// What a learner controls when making a sound. A step of the guide is about one of these.
enum MouthPart: String, CaseIterable, Hashable {
    case lips, jaw, tongue, air, voice

    var title: String {
        switch self {
        case .lips: return "Môi"
        case .jaw: return "Hàm"
        case .tongue: return "Lưỡi"
        case .air: return "Luồng hơi"
        case .voice: return "Dây thanh"
        }
    }
}

/// How far the step-by-step guide has got: which parts are already in position,
/// and which one the current step is about.
struct MouthGuideStep: Equatable {
    var applied: Set<MouthPart>
    var focus: MouthPart?
    var glides = false
}

/// How breath moves at a moment of speech; drives the airflow drawing.
enum AirCue: Equatable {
    case none, inhale, hold, burst, hiss, flow, nasal
}

/// Side view (cut-away) and front view of the mouth for one sound.
///
/// With `step == nil` the finished position is shown. A step shows the position built up so far,
/// starting from a relaxed mouth, and spotlights the part that step is about.
struct MouthDiagramView: View {
    let articulation: Articulation
    var compact = false
    var annotated = false
    var step: MouthGuideStep? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates)) { context in
            let time = animates ? context.date.timeIntervalSinceReferenceDate : 0
            let cue = airCue(at: time)
            AnimatedMouth(state: state(at: time, cue: cue), voiced: articulation.voiced,
                          nasal: articulation.nasal && applied.contains(.air),
                          air: cue, phase: time, annotated: annotated, focus: step?.focus,
                          showsVoice: applied.contains(.voice), compact: compact)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: step)
        }
    }

    private var applied: Set<MouthPart> { step?.applied ?? Set(MouthPart.allCases) }
    private var glides: Bool { articulation.end != nil && (step?.glides ?? true) }

    /// Motion carries information here (air direction, voicing, the glide), so it runs only while
    /// one of those is on screen, and never when Reduce Motion is on.
    private var animates: Bool {
        !reduceMotion && (glides || applied.contains(.air) || applied.contains(.voice))
    }

    private var isStop: Bool { articulation.manner == "stop" || articulation.manner == "affricate" }

    private func airCue(at time: Double) -> AirCue {
        guard applied.contains(.air) else { return .none }
        switch articulation.manner {
        case "stop": return animates && releasePhase(time) > 0 ? .burst : .hold
        case "affricate": return animates && releasePhase(time) > 0 ? .hiss : .hold
        case "fricative": return .hiss
        case "nasal": return .nasal
        default: return .flow
        }
    }

    /// Stops repeat "hold, then let go": 0 while held, rising to 1 as the closure opens.
    private func releasePhase(_ time: Double) -> Double {
        let cycle = time.truncatingRemainder(dividingBy: 2.0) / 2.0
        switch cycle {
        case ..<0.55: return 0
        case ..<0.65: return (cycle - 0.55) / 0.10
        case ..<0.90: return 1
        default: return 1 - (cycle - 0.90) / 0.10
        }
    }

    private func state(at time: Double, cue: AirCue) -> MouthState {
        let target = articulation.start
        let rest = ArticulationPose.rest
        let pose = ArticulationPose(
            lips: applied.contains(.lips) ? target.lips : rest.lips,
            jaw: applied.contains(.jaw) ? target.jaw : rest.jaw,
            tongueHeight: applied.contains(.tongue) ? target.tongueHeight : rest.tongueHeight,
            tongueFront: applied.contains(.tongue) ? target.tongueFront : rest.tongueFront,
            tip: applied.contains(.tongue) ? target.tip : rest.tip,
            contact: applied.contains(.tongue) && target.contact,
            backContact: applied.contains(.tongue) && target.backContact)
        var state = MouthState(pose)
        if let end = articulation.end, step?.glides ?? true {
            state = state.mixed(with: MouthState(end), reduceMotion ? (step == nil ? 0 : 1) : glidePhase(time))
        }
        if isStop, animates, applied.contains(.air) {
            state = state.released(releasePhase(time) * (articulation.manner == "affricate" ? 0.5 : 1))
        }
        return state
    }

    /// Hold the start, glide, hold the end, return: a 2.4 s loop.
    private func glidePhase(_ time: Double) -> Double {
        let cycle = time.truncatingRemainder(dividingBy: 2.4) / 2.4
        switch cycle {
        case ..<0.25: return 0
        case ..<0.55: return smooth((cycle - 0.25) / 0.30)
        case ..<0.85: return 1
        default: return 1 - smooth((cycle - 0.85) / 0.15)
        }
    }

    private func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }
}

/// Both views side by side; `state` is animatable so a step change moves the mouth instead of jumping.
private struct AnimatedMouth: View, Animatable {
    var state: MouthState
    let voiced: Bool
    let nasal: Bool
    let air: AirCue
    let phase: Double
    let annotated: Bool
    let focus: MouthPart?
    let showsVoice: Bool
    let compact: Bool

    var animatableData: MouthVector {
        get { state.animatableData }
        set { state.animatableData = newValue }
    }

    var body: some View {
        HStack(spacing: 12) {
            MouthSideCanvas(state: state, voiced: voiced, nasal: nasal, air: air, phase: phase,
                            annotated: annotated, focus: focus, showsVoice: showsVoice)
                .aspectRatio(1, contentMode: .fit)
            if !compact {
                LipsFrontCanvas(state: state, focus: focus)
                    .aspectRatio(0.8, contentMode: .fit)
                    .frame(maxWidth: 104)
            }
        }
    }
}

/// The diagram's marker colours, for a legend next to it.
enum MouthDiagramColors {
    static let air = MouthPalette.air
    static let contact = MouthPalette.contact
    static let voice = MouthPalette.voice
    static let voiceless = MouthPalette.gum
}

private enum MouthPalette {
    static let card = Color(red: 0.11, green: 0.09, blue: 0.22)
    static let skin = Color(red: 0.97, green: 0.80, blue: 0.70)
    static let skinShade = Color(red: 0.86, green: 0.62, blue: 0.55)
    static let cavity = Color(red: 0.25, green: 0.09, blue: 0.17)
    static let cavityNose = Color(red: 0.33, green: 0.14, blue: 0.22)
    static let bone = Color(red: 1.0, green: 0.94, blue: 0.87)
    static let gum = Color(red: 0.95, green: 0.56, blue: 0.60)
    static let velum = Color(red: 0.90, green: 0.47, blue: 0.53)
    static let tongue = Color(red: 0.93, green: 0.35, blue: 0.46)
    static let tongueDeep = Color(red: 0.74, green: 0.20, blue: 0.34)
    static let lip = Color(red: 0.84, green: 0.33, blue: 0.42)
    static let lipDeep = Color(red: 0.66, green: 0.20, blue: 0.30)
    static let tooth = Color(red: 1.0, green: 0.99, blue: 0.96)
    static let toothEdge = Color(red: 0.70, green: 0.66, blue: 0.72)
    static let air = Color(red: 0.42, green: 0.86, blue: 1.0)
    static let contact = Color(red: 1.0, green: 0.84, blue: 0.26)
    static let voice = Color(red: 0.72, green: 0.48, blue: 1.0)
    static let voiceOff = Color(red: 0.62, green: 0.40, blue: 0.46)
    static let labelInk = Color(red: 0.25, green: 0.12, blue: 0.16)
}

private func smoothPath(_ points: [CGPoint], closed: Bool) -> Path {
    var path = Path()
    let n = points.count
    guard n > 2 else { return path }
    func point(_ i: Int) -> CGPoint {
        closed ? points[(i % n + n) % n] : points[min(max(i, 0), n - 1)]
    }
    path.move(to: points[0])
    for i in 0..<(closed ? n : n - 1) {
        let p0 = point(i - 1), p1 = point(i), p2 = point(i + 1), p3 = point(i + 2)
        path.addCurve(to: p2,
                      control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                      control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
    }
    if closed { path.closeSubpath() }
    return path
}

/// Shapes of the cut-away head for one mouth state, in points. The face looks left;
/// positions are worked out in a unit square and scaled by `s`.
private struct SideMouthGeometry {
    let state: MouthState
    let s: CGFloat
    /// 0 = soft palate raised (air through the mouth), 1 = lowered (air through the nose).
    let velumDrop: CGFloat

    let jawDrop: CGFloat
    let lipGap: CGFloat
    let upperLipX: CGFloat
    let lowerLipX: CGFloat
    let hump: CGPoint
    let tip: CGPoint

    init(state: MouthState, nasal: Bool, size: CGFloat) {
        self.state = state
        s = size
        velumDrop = nasal ? 1 : 0
        jawDrop = CGFloat(state.jaw) * 0.12
        let labiodental = CGFloat(state.labiodental)
        upperLipX = 0.095 - CGFloat(state.round) * 0.035 + CGFloat(state.spread) * 0.012
        lowerLipX = upperLipX + 0.012 + labiodental * 0.058
        lipGap = CGFloat(1 - state.closed) * (1 - labiodental) * (0.018 + CGFloat(state.jaw) * 0.085)
            * (1 - CGFloat(state.round) * 0.35)
        tip = state.tip

        let freeX = 0.66 - CGFloat(state.tongueFront) * 0.24
        let high = Self.roofY(freeX, velumDrop: velumDrop) + 0.042
        let low = 0.585 + jawDrop
        let freeY = low - CGFloat(state.tongueHeight) * (low - high)
        let back = CGFloat(state.backContact)
        hump = CGPoint(x: freeX + (0.70 - freeX) * back,
                       y: freeY + (Self.roofY(0.70, velumDrop: velumDrop) + 0.004 - freeY) * back)
    }

    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
    func p(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * s, y: point.y * s) }

    /// Height of the roof of the mouth (hard palate, then the underside of the soft palate) at `x`.
    static func roofY(_ x: CGFloat, velumDrop: CGFloat) -> CGFloat {
        let stops: [(CGFloat, CGFloat)] = [
            (0.222, 0.392), (0.258, 0.374), (0.30, 0.350), (0.42, 0.322), (0.605, 0.333),
            (0.70, 0.348 + velumDrop * 0.034), (0.80, 0.374 + velumDrop * 0.09),
        ]
        guard x > stops[0].0 else { return stops[0].1 }
        for (a, b) in zip(stops, stops.dropFirst()) where x <= b.0 {
            return a.1 + (b.1 - a.1) * (x - a.0) / (b.0 - a.0)
        }
        return stops[stops.count - 1].1
    }

    func roofY(_ x: CGFloat) -> CGFloat { Self.roofY(x, velumDrop: velumDrop) }

    var teethGapY: CGFloat { (0.462 + 0.472 + jawDrop) / 2 }
    var lipsY: CGFloat { 0.455 + lipGap / 2 }

    // MARK: Skin

    var upperHead: Path {
        var path = Path()
        path.move(to: p(1.05, -0.05))
        path.addLine(to: p(0.38, -0.05))
        path.addQuadCurve(to: p(0.19, 0.135), control: p(0.27, 0.02))
        path.addQuadCurve(to: p(0.045, 0.262), control: p(0.13, 0.20))
        path.addQuadCurve(to: p(0.078, 0.302), control: p(0.030, 0.300))
        path.addQuadCurve(to: p(0.136, 0.322), control: p(0.112, 0.302))
        path.addQuadCurve(to: p(upperLipX + 0.010, 0.396), control: p(upperLipX + 0.022, 0.360))
        path.addQuadCurve(to: p(upperLipX + 0.04, 0.452), control: p(upperLipX - 0.008, 0.445))
        path.addLine(to: p(0.64, 0.46))
        path.addLine(to: p(0.585, 0.90))
        path.addLine(to: p(0.60, 1.05))
        path.addLine(to: p(1.05, 1.05))
        path.closeSubpath()
        return path
    }

    var mandible: Path {
        let y0 = 0.458 + lipGap
        var path = Path()
        path.move(to: p(lowerLipX + 0.04, y0))
        path.addQuadCurve(to: p(lowerLipX + 0.004, y0 + 0.05), control: p(lowerLipX - 0.010, y0 + 0.008))
        path.addQuadCurve(to: p(0.150, 0.585 + lipGap * 0.4 + jawDrop * 0.6), control: p(lowerLipX + 0.016, y0 + 0.090))
        path.addQuadCurve(to: p(0.122, 0.69 + jawDrop), control: p(0.118, 0.61 + jawDrop))
        path.addQuadCurve(to: p(0.215, 0.80 + jawDrop), control: p(0.125, 0.79 + jawDrop))
        path.addQuadCurve(to: p(0.585, 0.90), control: p(0.42, 0.86 + jawDrop * 0.7))
        path.addLine(to: p(0.66, 0.90))
        path.addLine(to: p(0.66, 0.46))
        path.closeSubpath()
        return path
    }

    // MARK: Hollow spaces

    /// Nose, mouth and throat as one hollow; the palate, tongue and teeth are drawn over it.
    var airway: Path {
        var path = Path()
        path.move(to: p(0.135, 0.312))
        path.addQuadCurve(to: p(0.36, 0.178), control: p(0.20, 0.19))
        path.addQuadCurve(to: p(0.66, 0.188), control: p(0.52, 0.152))
        path.addQuadCurve(to: p(0.87, 0.31), control: p(0.84, 0.19))
        path.addLine(to: p(0.87, 1.05))
        path.addLine(to: p(0.725, 1.05))
        path.addLine(to: p(0.725, 0.91))
        path.addQuadCurve(to: p(0.66, 0.80 + jawDrop * 0.3), control: p(0.71, 0.84))
        path.addQuadCurve(to: p(0.30, 0.655 + jawDrop), control: p(0.50, 0.80 + jawDrop * 0.7))
        path.addQuadCurve(to: p(0.234, 0.60 + jawDrop), control: p(0.245, 0.65 + jawDrop))
        path.addLine(to: p(0.234, 0.47 + jawDrop))
        path.addLine(to: p(lowerLipX + 0.05, 0.462 + lipGap))
        path.addLine(to: p(lowerLipX + 0.03, 0.460 + lipGap))
        path.addLine(to: p(upperLipX + 0.03, 0.452))
        path.addLine(to: p(upperLipX + 0.05, 0.450))
        path.addLine(to: p(0.166, 0.44))
        path.addLine(to: p(0.166, 0.335))
        path.closeSubpath()
        return path
    }

    /// The part of the hollow above the palate.
    var nasalCavity: Path {
        var path = Path()
        path.move(to: p(0.135, 0.312))
        path.addQuadCurve(to: p(0.36, 0.178), control: p(0.20, 0.19))
        path.addQuadCurve(to: p(0.66, 0.188), control: p(0.52, 0.152))
        path.addQuadCurve(to: p(0.87, 0.31), control: p(0.84, 0.19))
        path.addLine(to: p(0.87, 0.34))
        path.addLine(to: p(0.60, 0.30))
        path.addQuadCurve(to: p(0.166, 0.335), control: p(0.36, 0.268))
        path.closeSubpath()
        return path
    }

    // MARK: Roof of the mouth

    var palate: Path {
        var path = Path()
        path.move(to: p(0.160, 0.335))
        path.addQuadCurve(to: p(0.60, 0.292), control: p(0.36, 0.264))
        path.addLine(to: p(0.607, 0.333))
        path.addQuadCurve(to: p(0.42, 0.322), control: p(0.52, 0.318))
        path.addQuadCurve(to: p(0.30, 0.350), control: p(0.345, 0.325))
        path.addQuadCurve(to: p(0.258, 0.374), control: p(0.277, 0.358))
        path.addQuadCurve(to: p(0.222, 0.394), control: p(0.238, 0.392))
        path.addLine(to: p(0.162, 0.394))
        path.closeSubpath()
        return path
    }

    /// The gum line along the underside of the palate, from behind the teeth to the soft palate.
    var roofLining: Path {
        var path = Path()
        path.move(to: p(0.222, 0.394))
        path.addQuadCurve(to: p(0.258, 0.374), control: p(0.238, 0.392))
        path.addQuadCurve(to: p(0.30, 0.350), control: p(0.277, 0.358))
        path.addQuadCurve(to: p(0.42, 0.322), control: p(0.345, 0.325))
        path.addQuadCurve(to: p(0.607, 0.333), control: p(0.52, 0.318))
        return path
    }

    var velum: Path {
        func mix(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * velumDrop, y: a.y + (b.y - a.y) * velumDrop)
        }
        let topControl = mix(CGPoint(x: 0.75, y: 0.262), CGPoint(x: 0.77, y: 0.285))
        let tipTop = mix(CGPoint(x: 0.864, y: 0.338), CGPoint(x: 0.808, y: 0.43))
        let tipControl = mix(CGPoint(x: 0.878, y: 0.385), CGPoint(x: 0.806, y: 0.485))
        let tipBottom = mix(CGPoint(x: 0.838, y: 0.386), CGPoint(x: 0.762, y: 0.478))
        let bottomControl = mix(CGPoint(x: 0.74, y: 0.348), CGPoint(x: 0.715, y: 0.365))
        var path = Path()
        path.move(to: p(0.60, 0.292))
        path.addQuadCurve(to: p(tipTop), control: p(topControl))
        path.addQuadCurve(to: p(tipBottom), control: p(tipControl))
        path.addQuadCurve(to: p(0.607, 0.333), control: p(bottomControl))
        path.closeSubpath()
        return path
    }

    // MARK: Teeth, tongue, lips

    var upperTooth: Path {
        var path = Path()
        path.move(to: p(0.166, 0.388))
        path.addLine(to: p(0.220, 0.388))
        path.addQuadCurve(to: p(0.192, 0.464), control: p(0.226, 0.448))
        path.addQuadCurve(to: p(0.166, 0.388), control: p(0.158, 0.44))
        path.closeSubpath()
        return path
    }

    var lowerTooth: Path {
        let y = jawDrop
        var path = Path()
        path.move(to: p(0.178, 0.568 + y))
        path.addLine(to: p(0.230, 0.568 + y))
        path.addQuadCurve(to: p(0.202, 0.472 + y), control: p(0.236, 0.498 + y))
        path.addQuadCurve(to: p(0.178, 0.568 + y), control: p(0.170, 0.50 + y))
        path.closeSubpath()
        return path
    }

    /// Key points along the top of the tongue, used for the tongue shape and the air channel.
    var tongueBack: CGPoint {
        CGPoint(x: min(max(hump.x + 0.22, 0.72), 0.80), y: hump.y + (0.86 - hump.y) * 0.50)
    }
    var tongueDorsum: CGPoint { CGPoint(x: min(hump.x + 0.13, 0.79), y: hump.y + 0.028) }
    /// The top of the tongue a share of the way from tip to hump. With the hump far back the front
    /// stays low and rises late; with the hump at the front it rises straight away.
    func tongueTop(_ share: CGFloat) -> CGPoint {
        var rise = share
        if hump.y < tip.y {
            rise = pow(share, min(max(0.6 + 1.6 * (hump.x - 0.42) / 0.28, 0.6), 2.2))
        }
        return CGPoint(x: tip.x + (hump.x - tip.x) * share,
                       y: tip.y + (hump.y - tip.y) * rise - 0.022 * sin(.pi * share))
    }
    var tongueBlade: CGPoint { tongueTop(0.4) }

    var tongue: Path {
        let raised = min(max((0.50 - tip.y) / 0.12, 0), 1)
        var dx = 0.014 + raised * 0.040
        var dy = 0.055 + raised * 0.035
        if tip.x < 0.19 { dx += (0.19 - tip.x) * 1.5; dy -= 0.02 }
        if tip.x > 0.33 { dx -= (tip.x - 0.33) * 1.4 }
        // The underside runs below the floor of the mouth; the drawing clips it to the hollow.
        let points: [CGPoint] = [
            CGPoint(x: 0.705, y: 0.855 + jawDrop * 0.25),
            tongueBack,
            tongueDorsum,
            hump,
            tongueTop(0.75),
            tongueBlade,
            tip,
            CGPoint(x: tip.x + dx, y: tip.y + dy),
            CGPoint(x: 0.285 + raised * 0.045, y: 0.66 + jawDrop),
            CGPoint(x: 0.47, y: 0.87 + jawDrop),
        ]
        return smoothPath(points.map(p), closed: true)
    }

    var upperLip: Path {
        let x = upperLipX
        return smoothPath([p(x + 0.012, 0.394), p(x + 0.001, 0.426), p(x + 0.020, 0.454),
                           p(x + 0.064, 0.452), p(x + 0.050, 0.408)], closed: true)
    }

    var lowerLip: Path {
        let x = lowerLipX, y = 0.458 + lipGap
        return smoothPath([p(x + 0.022, y - 0.003), p(x + 0.001, y + 0.026), p(x + 0.012, y + 0.060),
                           p(x + 0.052, y + 0.050), p(x + 0.066, y + 0.002)], closed: true)
    }

    // MARK: Breath

    /// Where a blocked airstream stops, if the mouth is closed somewhere.
    var closure: CGPoint? {
        if state.backContact > 0.5 { return CGPoint(x: 0.80, y: 0.52) }
        if state.tipContact > 0.5 { return CGPoint(x: tip.x + 0.075, y: tip.y + 0.035) }
        if state.closed > 0.5 { return CGPoint(x: 0.245, y: teethGapY) }
        return nil
    }

    /// Centre line of the breath from the larynx out through the mouth.
    var oralStream: [CGPoint] {
        let back = tongueBack, dorsum = tongueDorsum, blade = tongueBlade
        return [
            CGPoint(x: 0.797, y: 1.0),
            CGPoint(x: (back.x + 0.87) / 2, y: back.y),
            CGPoint(x: (dorsum.x + 0.86) / 2, y: (dorsum.y + roofY(0.80)) / 2 + 0.02),
            CGPoint(x: hump.x, y: (roofY(hump.x) + hump.y) / 2),
            CGPoint(x: blade.x, y: (roofY(blade.x) + blade.y) / 2),
            CGPoint(x: 0.20, y: teethGapY),
            CGPoint(x: upperLipX + 0.03, y: lipsY),
            CGPoint(x: upperLipX - 0.085, y: lipsY),
        ]
    }

    /// Centre line of the breath from the larynx out through the nose.
    var nasalStream: [CGPoint] {
        let back = tongueBack
        return [
            CGPoint(x: 0.797, y: 1.0),
            CGPoint(x: (back.x + 0.87) / 2, y: back.y),
            CGPoint(x: 0.838, y: 0.44),
            CGPoint(x: 0.80, y: 0.275),
            CGPoint(x: 0.62, y: 0.228),
            CGPoint(x: 0.38, y: 0.226),
            CGPoint(x: 0.21, y: 0.272),
            CGPoint(x: 0.125, y: 0.330),
            CGPoint(x: 0.03, y: 0.375),
        ]
    }
}

/// Cut-away side view, face looking left. `phase` (seconds) animates airflow and vocal-fold vibration.
/// `focus` spotlights one part and dims the rest.
struct MouthSideCanvas: View {
    let state: MouthState
    let voiced: Bool
    let nasal: Bool
    var air: AirCue? = nil
    var phase: Double = 0
    var annotated = false
    var focus: MouthPart? = nil
    var showsVoice = true

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height)
            context.translateBy(x: (size.width - s) / 2, y: (size.height - s) / 2)
            let g = SideMouthGeometry(state: state, nasal: nasal, size: s)
            let u = s / 300
            let cue = air ?? (nasal ? .nasal : .flow)

            drawHead(&context, g, u)
            drawRoof(&context, g, u)
            context.fill(g.upperTooth, with: .color(MouthPalette.tooth))
            context.stroke(g.upperTooth, with: .color(MouthPalette.toothEdge), lineWidth: u)
            drawTongue(&context, g, u)
            drawLowerTooth(&context, g, u)
            drawLips(&context, g, u)
            drawContacts(&context, g, u)
            if showsVoice { drawVoice(&context, g, u) }
            drawAir(&context, g, u, cue)

            if let focus {
                context.fill(Path(CGRect(x: -s, y: -s, width: 3 * s, height: 3 * s)),
                             with: .color(MouthPalette.card.opacity(0.62)))
                // Small parts get a dashed ring as well, so the eye finds them at once.
                func ring(around rect: CGRect, _ padding: CGFloat) {
                    let r = max(rect.width, rect.height) / 2 + padding
                    let circle = Path(ellipseIn: CGRect(x: rect.midX - r, y: rect.midY - r, width: 2 * r, height: 2 * r))
                    context.stroke(circle, with: .color(.white.opacity(0.9)),
                                   style: StrokeStyle(lineWidth: 2 * u, dash: [6 * u, 4 * u]))
                }
                switch focus {
                case .lips:
                    drawLips(&context, g, u, outlined: true)
                    ring(around: g.upperLip.boundingRect.union(g.lowerLip.boundingRect), 10 * u)
                case .jaw:
                    context.drawLayer { layer in
                        var outside = Path(CGRect(x: -s, y: -s, width: 3 * s, height: 3 * s))
                        outside.addPath(g.airway)
                        layer.clip(to: outside, style: FillStyle(eoFill: true))
                        layer.fill(g.mandible, with: .color(MouthPalette.skin))
                    }
                    drawLowerTooth(&context, g, u)
                    drawLips(&context, g, u, lowerOnly: true)
                    drawJawArrow(&context, g, u)
                case .tongue:
                    drawTongue(&context, g, u, outlined: true)
                    drawLowerTooth(&context, g, u)
                    drawContacts(&context, g, u)
                case .air:
                    drawAir(&context, g, u, cue)
                case .voice:
                    drawVoice(&context, g, u)
                    ring(around: CGRect(x: g.p(0.70, 0.925).x, y: g.p(0, 0.925).y, width: 0.19 * s, height: 0), 4 * u)
                }
            }
            if annotated && s >= 200 { drawLabels(&context, g, u) }
        }
        .background(MouthPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mặt cắt khoang miệng nhìn từ bên cạnh")
        .accessibilityAddTraits(.isImage)
    }

    private func drawHead(_ context: inout GraphicsContext, _ g: SideMouthGeometry, _ u: CGFloat) {
        let skin = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [MouthPalette.skin, MouthPalette.skinShade]),
            startPoint: g.p(0.1, 0.2), endPoint: g.p(1.0, 1.0))
        context.fill(g.upperHead, with: skin)
        context.fill(g.mandible, with: skin)
        // A lining around the hollow, kept off the places where it opens to the outside.
        context.drawLayer { layer in
            var head = g.upperHead
            head.addPath(g.mandible)
            layer.clip(to: head)
            layer.stroke(g.airway, with: .color(MouthPalette.gum.opacity(0.85)), lineWidth: 6 * u)
        }
        context.fill(g.airway, with: .color(MouthPalette.cavity))
        context.fill(g.nasalCavity, with: .color(MouthPalette.cavityNose))
    }

    private func drawRoof(_ context: inout GraphicsContext, _ g: SideMouthGeometry, _ u: CGFloat) {
        context.fill(g.palate, with: .color(MouthPalette.bone))
        context.stroke(g.roofLining, with: .color(MouthPalette.gum),
                       style: StrokeStyle(lineWidth: 5 * u, lineCap: .round, lineJoin: .round))
        context.fill(g.velum, with: .color(MouthPalette.velum))
    }

    private func drawTongue(_ context: inout GraphicsContext, _ g: SideMouthGeometry, _ u: CGFloat, outlined: Bool = false) {
        let tongue = g.tongue
        context.drawLayer { layer in
            layer.clip(to: g.airway)
            layer.fill(tongue, with: .linearGradient(
                Gradient(colors: [MouthPalette.tongue, MouthPalette.tongueDeep]),
                startPoint: g.p(0.4, 0.35), endPoint: g.p(0.6, 0.95)))
            layer.stroke(tongue, with: .color(outlined ? .white : MouthPalette.tongueDeep),
                         lineWidth: (outlined ? 2.4 : 1.2) * u)
        }
    }

    private func drawLowerTooth(_ context: inout GraphicsContext, _ g: SideMouthGeometry, _ u: CGFloat) {
        context.fill(g.lowerTooth, with: .color(MouthPalette.tooth))
        context.stroke(g.lowerTooth, with: .color(MouthPalette.toothEdge), lineWidth: u)
    }

    private func drawLips(_ context: inout GraphicsContext, _ g: SideMouthGeometry, _ u: CGFloat,
                          outlined: Bool = false, lowerOnly: Bool = false) {
        for lip in lowerOnly ? [g.lowerLip] : [g.upperLip, g.lowerLip] {
            context.fill(lip, with: .color(MouthPalette.lip))
            if outlined { context.stroke(lip, with: .color(.white), lineWidth: 2.4 * u) }
        }
    }

    /// A bright dot wherever two parts touch: the thing a learner most needs to find.
    private func drawContacts(_ context: inout GraphicsContext, _ g: SideMouthGeometry, _ u: CGFloat) {
        var points: [CGPoint] = []
        if state.tipContact > 0.5 { points.append(g.p(g.tip)) }
        if state.backContact > 0.5 { points.append(g.p(g.hump)) }
        if state.closed > 0.5 { points.append(g.p(g.upperLipX + 0.022, 0.456)) }
        if state.labiodental > 0.5 { points.append(g.p(0.192, 0.462)) }
        for point in points {
            let halo = CGRect(x: point.x - 9 * u, y: point.y - 9 * u, width: 18 * u, height: 18 * u)
            context.fill(Path(ellipseIn: halo), with: .color(MouthPalette.contact.opacity(0.35)))
            let dot = CGRect(x: point.x - 4.5 * u, y: point.y - 4.5 * u, width: 9 * u, height: 9 * u)
            context.fill(Path(ellipseIn: dot), with: .color(MouthPalette.contact))
            context.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: u)
        }
    }

    /// Vocal folds across the throat: together and buzzing when voiced, apart when not.
    private func drawVoice(_ context: inout GraphicsContext, _ g: SideMouthGeometry, _ u: CGFloat) {
        let y: CGFloat = 0.925
        let buzz = voiced ? CGFloat(sin(phase * 38)) * 0.004 : 0
        let reach: CGFloat = voiced ? 0.070 + buzz : 0.030
        let color = voiced ? MouthPalette.voice : MouthPalette.gum
        for (wall, direction) in [(CGFloat(0.725), CGFloat(1)), (CGFloat(0.87), CGFloat(-1))] {
            var fold = Path()
            fold.move(to: g.p(wall, y - 0.022))
            fold.addQuadCurve(to: g.p(wall, y + 0.022), control: g.p(wall + direction * reach * 2, y))
            fold.closeSubpath()
            context.fill(fold, with: .color(color))
        }
        guard voiced else { return }
        // Ripples on the front of the neck: where a hand feels the buzz.
        for (i, radius) in [CGFloat(0.045), 0.075, 0.105].enumerated() {
            let pulse = 0.55 + 0.45 * sin(phase * 7 - Double(i) * 1.1)
            var arc = Path()
            arc.addArc(center: g.p(0.70, y), radius: radius * g.s,
                       startAngle: .degrees(150), endAngle: .degrees(210), clockwise: false)
            context.stroke(arc, with: .color(MouthPalette.voice.opacity(phase == 0 ? 0.9 : pulse)),
                           style: StrokeStyle(lineWidth: 2.4 * u, lineCap: .round))
        }
    }

    private func drawAir(_ context: inout GraphicsContext, _ g: SideMouthGeometry, _ u: CGFloat, _ cue: AirCue) {
        guard cue != .none else { return }
        var points: [CGPoint]
        var blockedAt: CGPoint?
        switch cue {
        case .nasal: points = g.nasalStream
        case .inhale: points = g.nasalStream.reversed()
        case .hold:
            points = g.oralStream
            if let closure = g.closure {
                // Keep the stream up to the closure, then stop it there.
                let reach = points.firstIndex(where: { $0.x < closure.x }) ?? points.count
                points = Array(points.prefix(max(reach, 2))) + [closure]
                blockedAt = closure
            }
        default: points = g.oralStream
        }
        let path = smoothPath(points.map(g.p), closed: false)
        let speed: Double = cue == .burst ? 90 : cue == .hiss ? 60 : cue == .hold ? 0 : 36
        context.stroke(path, with: .color(MouthPalette.air.opacity(0.22)),
                       style: StrokeStyle(lineWidth: 9 * u, lineCap: .round, lineJoin: .round))
        context.stroke(path, with: .color(MouthPalette.air),
                       style: StrokeStyle(lineWidth: (cue == .burst ? 3.6 : 2.8) * u, lineCap: .round, lineJoin: .round,
                                          dash: [7 * u, 6 * u], dashPhase: CGFloat(-phase * speed) * u))

        let end = g.p(points[points.count - 1]), before = g.p(points[points.count - 2])
        if let blockedAt {
            // Pressure building behind the closure.
            let center = g.p(blockedAt)
            for (i, radius) in [CGFloat(7), 12].enumerated() {
                let pulse = 1 + 0.18 * CGFloat(sin(phase * 9 + Double(i)))
                let r = radius * u * pulse
                context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(MouthPalette.contact.opacity(i == 0 ? 0.95 : 0.55)), lineWidth: 2 * u)
            }
        } else {
            let angle = atan2(end.y - before.y, end.x - before.x)
            var head = Path()
            head.move(to: end)
            head.addLine(to: CGPoint(x: end.x - 11 * u * cos(angle - 0.45), y: end.y - 11 * u * sin(angle - 0.45)))
            head.addLine(to: CGPoint(x: end.x - 11 * u * cos(angle + 0.45), y: end.y - 11 * u * sin(angle + 0.45)))
            head.closeSubpath()
            context.fill(head, with: .color(MouthPalette.air))
        }

        let lips = g.p(g.upperLipX - 0.01, g.lipsY)
        if cue == .burst {
            for angle in [-0.5, 0.5] {
                var puff = Path()
                puff.move(to: CGPoint(x: lips.x - 8 * u * cos(angle), y: lips.y + 8 * u * sin(angle)))
                puff.addLine(to: CGPoint(x: lips.x - 24 * u * cos(angle), y: lips.y + 24 * u * sin(angle)))
                context.stroke(puff, with: .color(MouthPalette.air),
                               style: StrokeStyle(lineWidth: 3 * u, lineCap: .round))
            }
        } else if cue == .hiss {
            // Rough, noisy air: short ripples either side of the stream.
            for side in [CGFloat(-1), 1] {
                var ripple = Path()
                ripple.move(to: CGPoint(x: lips.x - 2 * u, y: lips.y + side * 9 * u))
                for i in 1...4 {
                    let wobble = (i % 2 == 0 ? CGFloat(2.5) : -2.5) * u
                    ripple.addLine(to: CGPoint(x: lips.x - (2 + CGFloat(i) * 5.5) * u, y: lips.y + side * 9 * u + wobble))
                }
                context.stroke(ripple, with: .color(MouthPalette.air.opacity(0.8)),
                               style: StrokeStyle(lineWidth: 1.6 * u, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func drawJawArrow(_ context: inout GraphicsContext, _ g: SideMouthGeometry, _ u: CGFloat) {
        let x: CGFloat = 0.06
        let top = g.p(x, 0.60), bottom = g.p(x, 0.70 + g.jawDrop)
        var arrow = Path()
        arrow.move(to: top)
        arrow.addLine(to: bottom)
        arrow.move(to: CGPoint(x: bottom.x - 6 * u, y: bottom.y - 8 * u))
        arrow.addLine(to: bottom)
        arrow.addLine(to: CGPoint(x: bottom.x + 6 * u, y: bottom.y - 8 * u))
        context.stroke(arrow, with: .color(.white), style: StrokeStyle(lineWidth: 2.6 * u, lineCap: .round, lineJoin: .round))
    }

    private func drawLabels(_ context: inout GraphicsContext, _ g: SideMouthGeometry, _ u: CGFloat) {
        // A fixed 11 pt: the labels belong to the picture, which keeps its size at any Dynamic Type
        // setting, and on a light pill they read over any part of it.
        func label(_ text: String, at point: CGPoint, anchor: UnitPoint = .center) {
            let resolved = context.resolve(SwiftUI.Text(text).font(.system(size: 11, weight: .semibold))
                .foregroundColor(MouthPalette.labelInk))
            let size = resolved.measure(in: CGSize(width: g.s, height: g.s))
            let box = CGSize(width: size.width + 8, height: size.height + 3)
            let x = min(max(point.x - box.width * anchor.x, 2), g.s - box.width - 2)
            let rect = CGRect(origin: CGPoint(x: x, y: point.y - box.height * anchor.y), size: box)
            context.fill(Path(roundedRect: rect, cornerRadius: box.height / 2), with: .color(.white.opacity(0.9)))
            context.draw(resolved, in: rect.insetBy(dx: 4, dy: 1.5))
        }
        func leader(from: CGPoint, to: CGPoint) {
            var line = Path()
            line.move(to: from)
            line.addLine(to: to)
            context.stroke(line, with: .color(MouthPalette.labelInk.opacity(0.75)), lineWidth: u)
            context.fill(Path(ellipseIn: CGRect(x: to.x - 2.5 * u, y: to.y - 2.5 * u, width: 5 * u, height: 5 * u)),
                         with: .color(MouthPalette.labelInk))
        }
        leader(from: g.p(0.25, 0.11), to: g.p(0.262, 0.366))
        leader(from: g.p(0.48, 0.11), to: g.p(0.46, 0.305))
        leader(from: g.p(0.80, 0.11), to: g.p(0.72, 0.31 + g.velumDrop * 0.03))
        leader(from: g.p(0.59, 0.95), to: g.p(0.74, 0.925))
        label("khoang mũi", at: g.p(0.47, 0.232))
        label("lưỡi", at: g.p(min(g.hump.x + 0.03, 0.62), max(g.hump.y + 0.13, 0.60)))
        label("lợi", at: g.p(0.25, 0.095))
        label("ngạc cứng", at: g.p(0.495, 0.095))
        label("ngạc mềm", at: g.p(0.835, 0.095))
        label("dây thanh", at: g.p(0.59, 0.95), anchor: .trailing)
    }
}

/// The lower face seen from the front.
struct LipsFrontCanvas: View {
    let state: MouthState
    var focus: MouthPart? = nil

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let u = w / 104
            let cx = w / 2, cy = h * 0.60

            // Lower face: cheeks, the base of the nose, the chin.
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: [MouthPalette.skin, MouthPalette.skinShade]),
                startPoint: CGPoint(x: cx, y: 0), endPoint: CGPoint(x: cx, y: h * 1.25)))
            var nose = Path()
            nose.move(to: CGPoint(x: cx - 15 * u, y: h * 0.17))
            nose.addQuadCurve(to: CGPoint(x: cx, y: h * 0.215), control: CGPoint(x: cx - 9 * u, y: h * 0.235))
            nose.addQuadCurve(to: CGPoint(x: cx + 15 * u, y: h * 0.17), control: CGPoint(x: cx + 9 * u, y: h * 0.235))
            context.stroke(nose, with: .color(MouthPalette.skinShade), style: StrokeStyle(lineWidth: 2.2 * u, lineCap: .round))
            for side in [CGFloat(-1), 1] {
                let nostril = CGRect(x: cx + side * 8 * u - 3.5 * u, y: h * 0.165, width: 7 * u, height: 4.5 * u)
                context.fill(Path(ellipseIn: nostril), with: .color(MouthPalette.lipDeep.opacity(0.55)))
            }
            var chin = Path()
            chin.move(to: CGPoint(x: cx - 16 * u, y: h * 0.90))
            chin.addQuadCurve(to: CGPoint(x: cx + 16 * u, y: h * 0.90), control: CGPoint(x: cx, y: h * 0.86))
            context.stroke(chin, with: .color(MouthPalette.skinShade.opacity(0.8)), style: StrokeStyle(lineWidth: 2 * u, lineCap: .round))

            let round = CGFloat(state.round), spread = CGFloat(state.spread)
            let labiodental = CGFloat(state.labiodental)
            let half = w * (0.30 + spread * 0.08 - round * 0.13)
            let isClosed = state.closed > 0.5
            let open = isClosed ? 0 : h * (0.035 + CGFloat(state.jaw) * 0.25) * (1 - labiodental * 0.75) * (1 + round * 0.25)
            let upper = h * (0.060 + round * 0.022)
            let lower = h * (0.078 + round * 0.026)
            let left = CGPoint(x: cx - half, y: cy - spread * h * 0.012)
            let right = CGPoint(x: cx + half, y: cy - spread * h * 0.012)
            let topInner = cy - open * 0.45, bottomInner = cy + open * 0.55

            var lips = Path()
            lips.move(to: left)
            lips.addCurve(to: CGPoint(x: cx - half * 0.26, y: topInner - upper * 1.12),
                          control1: CGPoint(x: cx - half * 0.80, y: topInner - upper * 0.35),
                          control2: CGPoint(x: cx - half * 0.52, y: topInner - upper * 1.12))
            lips.addQuadCurve(to: CGPoint(x: cx, y: topInner - upper * 0.86), control: CGPoint(x: cx - half * 0.10, y: topInner - upper * 1.10))
            lips.addQuadCurve(to: CGPoint(x: cx + half * 0.26, y: topInner - upper * 1.12), control: CGPoint(x: cx + half * 0.10, y: topInner - upper * 1.10))
            lips.addCurve(to: right,
                          control1: CGPoint(x: cx + half * 0.52, y: topInner - upper * 1.12),
                          control2: CGPoint(x: cx + half * 0.80, y: topInner - upper * 0.35))
            lips.addCurve(to: left,
                          control1: CGPoint(x: cx + half * 0.62, y: bottomInner + lower * 1.45),
                          control2: CGPoint(x: cx - half * 0.62, y: bottomInner + lower * 1.45))
            lips.closeSubpath()
            context.fill(lips, with: .linearGradient(
                Gradient(colors: [MouthPalette.lip, MouthPalette.lipDeep]),
                startPoint: CGPoint(x: cx, y: topInner - upper), endPoint: CGPoint(x: cx, y: bottomInner + lower * 2.2)))

            let inset = half * (0.86 - round * 0.12)
            var mouth = Path()
            mouth.move(to: CGPoint(x: cx - inset, y: left.y))
            mouth.addQuadCurve(to: CGPoint(x: cx + inset, y: right.y), control: CGPoint(x: cx, y: 2 * topInner - left.y))
            mouth.addQuadCurve(to: CGPoint(x: cx - inset, y: left.y), control: CGPoint(x: cx, y: 2 * bottomInner - left.y))
            mouth.closeSubpath()

            if open > 0.5 {
                context.fill(mouth, with: .color(MouthPalette.cavity))
                context.drawLayer { layer in
                    layer.clip(to: mouth)
                    // Tongue on the floor of the mouth; lower when the tongue is low.
                    let tongueTop = bottomInner - open * (0.30 + 0.30 * CGFloat(state.tongueHeight))
                    layer.fill(Path(ellipseIn: CGRect(x: cx - inset * 0.72, y: tongueTop, width: inset * 1.44, height: open * 1.3)),
                               with: .color(MouthPalette.tongue))
                    let teeth = min(open * 0.42, h * 0.085)
                    let band = CGRect(x: cx - inset, y: topInner - teeth, width: inset * 2, height: teeth * 2)
                    layer.fill(Path(roundedRect: band, cornerRadius: 3 * u), with: .color(MouthPalette.tooth))
                    var gaps = Path()
                    for i in -2...2 {
                        let x = cx + CGFloat(i) * inset * 0.30
                        gaps.move(to: CGPoint(x: x - inset * 0.15, y: band.minY))
                        gaps.addLine(to: CGPoint(x: x - inset * 0.15, y: band.maxY))
                        gaps.move(to: CGPoint(x: x + inset * 0.15, y: band.minY))
                        gaps.addLine(to: CGPoint(x: x + inset * 0.15, y: band.maxY))
                    }
                    layer.stroke(gaps, with: .color(MouthPalette.toothEdge.opacity(0.7)), lineWidth: 0.8 * u)
                    if state.tip.x < 0.19 {
                        // Tongue tip showing between the teeth.
                        let tipRect = CGRect(x: cx - inset * 0.42, y: topInner + teeth * 0.55, width: inset * 0.84, height: max(open * 0.55, 7 * u))
                        layer.fill(Path(ellipseIn: tipRect), with: .color(MouthPalette.tongue))
                        layer.stroke(Path(ellipseIn: tipRect), with: .color(MouthPalette.tongueDeep), lineWidth: u)
                    }
                }
            } else {
                var seam = Path()
                seam.move(to: CGPoint(x: left.x + 3 * u, y: left.y))
                seam.addQuadCurve(to: CGPoint(x: right.x - 3 * u, y: right.y), control: CGPoint(x: cx, y: cy + 3 * u))
                context.stroke(seam, with: .color(MouthPalette.lipDeep), style: StrokeStyle(lineWidth: 2.2 * u, lineCap: .round))
            }
            if labiodental > 0.5 {
                // Upper teeth resting on the lower lip.
                let band = CGRect(x: cx - half * 0.50, y: cy - 2 * u, width: half, height: 9 * u)
                context.fill(Path(roundedRect: band, cornerRadius: 2.5 * u), with: .color(MouthPalette.tooth))
                var gaps = Path()
                for i in 1...3 {
                    let x = band.minX + band.width * CGFloat(i) / 4
                    gaps.move(to: CGPoint(x: x, y: band.minY))
                    gaps.addLine(to: CGPoint(x: x, y: band.maxY))
                }
                context.stroke(gaps, with: .color(MouthPalette.toothEdge.opacity(0.7)), lineWidth: 0.8 * u)
            }
            // A soft highlight on the lower lip.
            let shine = CGRect(x: cx - half * 0.34, y: bottomInner + lower * 0.50, width: half * 0.68, height: lower * 0.28)
            context.fill(Path(ellipseIn: shine), with: .color(.white.opacity(0.22)))

            if let focus, focus != .lips, focus != .jaw {
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(MouthPalette.card.opacity(0.62)))
            } else if focus == .lips {
                context.stroke(lips, with: .color(.white), lineWidth: 2 * u)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Khẩu hình môi nhìn từ phía trước")
        .accessibilityAddTraits(.isImage)
    }
}
