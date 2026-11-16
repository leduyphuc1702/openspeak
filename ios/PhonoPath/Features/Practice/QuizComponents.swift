import SwiftUI

enum AnswerState: Equatable {
    case unanswered
    case answered(choice: Int, correct: Int)

    func style(for index: Int) -> (background: Color, border: Color) {
        guard case let .answered(choice, correct) = self else {
            return (Theme.surface, Theme.subtle)
        }
        if index == correct { return (Theme.good.opacity(0.15), Theme.good) }
        if index == choice { return (Theme.bad.opacity(0.15), Theme.bad) }
        return (Theme.surface, Theme.subtle)
    }

    func mark(for index: Int) -> AnswerMark? {
        guard case let .answered(choice, correct) = self else { return nil }
        if index == correct { return .right }
        return index == choice ? .wrong : nil
    }

    var isAnswered: Bool { self != .unanswered }
}

enum AnswerMark {
    case right, wrong
}

extension View {
    /// Marks an answer with a symbol as well as a colour, so the result can be read without telling green from red.
    func answerMark(_ mark: AnswerMark?) -> some View {
        overlay(alignment: .topTrailing) {
            if let mark {
                Image(systemName: mark == .right ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(mark == .right ? Theme.good : Theme.bad)
                    .padding(8)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityValue(mark == nil ? "" : mark == .right ? "Đáp án đúng" : "Chưa đúng")
    }
}

struct QuizHeader: View {
    let index: Int
    let total: Int
    let score: Int

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Câu \(min(index + 1, total))/\(total)").font(.subheadline.bold())
                Spacer()
                Label("\(score)", systemImage: "star.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(Theme.ok)
            }
            ProgressView(value: Double(index), total: Double(total))
                .tint(Theme.primary)
        }
    }
}

struct OptionButton<Label: View>: View {
    let index: Int
    let state: AnswerState
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        let style = state.style(for: index)
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(style.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(style.border, lineWidth: 2))
                .answerMark(state.mark(for: index))
        }
        .buttonStyle(FlatButtonStyle())
        .disabled(state.isAnswered)
        .accessibilityIdentifier("option.\(index)")
    }
}

struct QuizSummaryView: View {
    let score: Int
    let total: Int
    var actionTitle = "Làm lại"
    let restart: () -> Void

    private var percent: Int { total == 0 ? 0 : score * 100 / total }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ScoreRing(score: percent, size: 150, lineWidth: 14)
            Text(percent >= 80 ? "Xuất sắc!" : percent >= 50 ? "Khá tốt, luyện thêm nhé" : "Cùng ôn lại nào")
                .font(.title2.bold())
            Text("Đúng \(score)/\(total) câu").foregroundStyle(.secondary)
            Spacer()
            Button(actionTitle, action: restart).buttonStyle(PrimaryButtonStyle())
        }
    }
}

extension Array {
    /// `count` random elements, always including `required`, in shuffled order.
    func options(including required: Element, count: Int, where isSame: (Element, Element) -> Bool) -> [Element] {
        let others = filter { !isSame($0, required) }.shuffled().prefix(count - 1)
        return ([required] + others).shuffled()
    }
}
