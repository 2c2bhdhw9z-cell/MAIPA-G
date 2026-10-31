import AgentCore
import SwiftUI

/// The AI's numbered questions, each with answer buttons, plus "Something else" for typing an
/// answer. Answers go back together once each question has one.
struct QuestionCard: View {
    var questions: QuestionSet
    var onSubmit: ([String]) -> Void

    /// The tapped choice per question.
    @State private var chosen: [String]
    /// What's typed per question, used while that question's "Something else" is picked.
    @State private var typed: [String]
    @State private var typing: Set<Int> = []
    @FocusState private var focused: Int?
    @Environment(\.theme) private var theme

    init(questions: QuestionSet, onSubmit: @escaping ([String]) -> Void) {
        self.questions = questions
        self.onSubmit = onSubmit
        _chosen = State(initialValue: Array(repeating: "", count: questions.questions.count))
        _typed = State(initialValue: Array(repeating: "", count: questions.questions.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(questions.questions.count == 1 ? "A quick question" : "A few questions", systemImage: "questionmark.bubble")
                .font(.rounded(.headline))
                .foregroundStyle(theme.accent)
            ForEach(Array(questions.questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 10) {
                    Text(questions.questions.count == 1 ? question.text : "\(index + 1). \(question.text)")
                        .font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    FlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(question.options, id: \.self) { option in
                            optionButton(option, for: index)
                        }
                        optionButton(nil, for: index)
                    }
                    if typing.contains(index), index < typed.count {
                        TextField("Your answer", text: $typed[index], axis: .vertical)
                            .lineLimit(1...4)
                            .textFieldStyle(.roundedBorder)
                            .focused($focused, equals: index)
                            .submitLabel(.done)
                    }
                }
            }
            PrimaryButton(title: questions.questions.count == 1 ? "Send answer" : "Send answers", systemImage: "arrow.up") {
                focused = nil
                KeyboardDismiss.dismiss()
                onSubmit(answers)
            }
            .disabled(!allAnswered)
            .opacity(allAnswered ? 1 : 0.5)
        }
        .card(cornerRadius: 20, padding: 16)
        .onChange(of: questions) { _, newQuestions in
            chosen = Array(repeating: "", count: newQuestions.questions.count)
            typed = Array(repeating: "", count: newQuestions.questions.count)
            typing.removeAll()
            focused = nil
        }
    }

    private var answers: [String] {
        questions.questions.indices.map { index in
            let answer = typing.contains(index) ? typed[safe: index] : chosen[safe: index]
            return (answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var allAnswered: Bool {
        answers.allSatisfy { !$0.isEmpty }
    }

    /// One answer button; nil makes the "Something else" one that opens a text box.
    @ViewBuilder
    private func optionButton(_ option: String?, for index: Int) -> some View {
        let isSelected = option.map { chosen[safe: index] == $0 && !typing.contains(index) } ?? typing.contains(index)
        Button {
            Haptics.selection()
            if let option {
                if index < chosen.count { chosen[index] = option }
                typing.remove(index)
            } else {
                typing.insert(index)
                focused = index
            }
        } label: {
            Text(option ?? "Something else…")
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? Color.black.opacity(0.85) : .primary)
                .background {
                    if isSelected {
                        Capsule().fill(theme.gradient)
                    } else {
                        Capsule().fill(Theme.raised)
                    }
                }
                .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Theme.stroke))
        }
        .buttonStyle(.plain)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
