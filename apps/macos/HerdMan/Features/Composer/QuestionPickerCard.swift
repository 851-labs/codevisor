import SwiftUI
import AppKit
import HerdManCore
import ACPKit

/// The composer's question mode: when the agent asks a multiple-choice
/// question the input card becomes this picker — modeled on codex CLI's
/// bottom pane.
///
/// Selection model: exactly one of the options (including "Other") for
/// single-select questions; multi-select questions toggle. The notes editor
/// is always visible below the options — optional alongside a selection,
/// required when "Other" is chosen (it IS the answer) — so choosing "Other"
/// never shifts the layout.
///
/// Multiple questions show one at a time with progress; answers accumulate
/// locally and submit once after the last question (codex behavior).
struct QuestionPickerCard: View {
    @Environment(\.theme) private var theme
    @Bindable var controller: SessionController
    let request: QuestionRequest

    /// Sentinel stored in `selections` when the "Other" row is chosen.
    private static let otherToken = "__other__"

    @State private var questionIndex = 0
    /// Accumulated selections per question id (option labels + otherToken).
    @State private var selections: [String: Set<String>] = [:]
    /// Notes per question id — supplementary for options, the answer for Other.
    @State private var notes: [String: String] = [:]
    @State private var notesHeight: CGFloat = 24
    @State private var highlighted = 0
    @FocusState private var isPickerFocused: Bool

    private var question: QuestionSpec? {
        request.questions.indices.contains(questionIndex) ? request.questions[questionIndex] : nil
    }

    private var isLastQuestion: Bool { questionIndex >= request.questions.count - 1 }

    /// "Other" needs its note text — everything else can submit freely
    /// (unanswered questions are allowed, codex-style).
    private var isSubmittable: Bool {
        request.questions.allSatisfy { question in
            let selected = selections[question.id, default: []]
            let note = (notes[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !selected.contains(Self.otherToken) || !note.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let question {
                if let message = request.message, !message.isEmpty {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                header(question)
                optionList(question)
                notesEditor(question)
                footer(question)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(theme.composerBackground))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
        .focusable()
        .focused($isPickerFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            handleKey(press)
        }
        .onAppear {
            isPickerFocused = true
            highlighted = 0
        }
        .onChange(of: request.questionId) { _, _ in
            questionIndex = 0
            selections = [:]
            notes = [:]
            highlighted = 0
            isPickerFocused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent question")
    }

    // MARK: - Sections

    private func header(_ question: QuestionSpec) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(question.question)
                .font(.callout.weight(.medium))
            Spacer(minLength: 0)
            Button {
                Task { await controller.cancelQuestion() }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss without answering (Esc)")
        }
    }

    private func optionList(_ question: QuestionSpec) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                optionRow(
                    question,
                    index: index,
                    label: option.label,
                    description: option.description,
                    isSelected: selections[question.id, default: []].contains(option.label)
                )
            }
            if question.allowsOther {
                optionRow(
                    question,
                    index: question.options.count,
                    label: "Other",
                    description: "Answer in your own words below.",
                    isSelected: selections[question.id, default: []].contains(Self.otherToken)
                )
            }
        }
    }

    private func optionRow(
        _ question: QuestionSpec,
        index: Int,
        label: String,
        description: String?,
        isSelected: Bool
    ) -> some View {
        let isHighlighted = index == highlighted
        return Button {
            highlighted = index
            activate(question, index: index)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(
                        isHighlighted ? AnyShapeStyle(theme.windowBackground) :
                            isSelected ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.tertiary)
                    )
                Text(label)
                    .fontWeight(.medium)
                if let description, !description.isEmpty {
                    Text(description)
                        .lineLimit(1)
                        .foregroundStyle(isHighlighted ? AnyShapeStyle(theme.windowBackground.opacity(0.85)) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 0)
                if index < 9 {
                    Text("\(index + 1)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(isHighlighted ? AnyShapeStyle(theme.windowBackground.opacity(0.6)) : AnyShapeStyle(.quaternary))
                }
            }
            .foregroundStyle(isHighlighted ? theme.windowBackground : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(isHighlighted ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.clear)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label + (description.map { ", \($0)" } ?? ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The same auto-resizing editor as the composer, boxed so it reads as a
    /// field inside the picker. Always mounted — no layout shift on "Other".
    private func notesEditor(_ question: QuestionSpec) -> some View {
        let isOtherSelected = selections[question.id, default: []].contains(Self.otherToken)
        return ZStack(alignment: .topLeading) {
            ChatInputEditor(
                text: notesBinding(question),
                calculatedHeight: $notesHeight,
                minHeight: 24,
                maxHeight: 120,
                onSubmit: { advanceOrSubmit() },
                onKeyCommand: { command in
                    // Escape hops focus back to the option list; a second
                    // Escape there dismisses the question.
                    if command == .dismissSelection {
                        isPickerFocused = true
                        return true
                    }
                    return false
                }
            )
            .frame(height: notesHeight)
            if (notes[question.id] ?? "").isEmpty {
                Text(isOtherSelected ? "Type your answer (required)" : "Add a note (optional)")
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.windowBackground.opacity(0.55)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isOtherSelected ? Color.primary.opacity(0.35) : Color(nsColor: .separatorColor),
                    lineWidth: 1
                )
        )
    }

    private func footer(_ question: QuestionSpec) -> some View {
        HStack(spacing: 8) {
            Text(question.multiSelect == true
                ? "Space toggles · Return continues · Esc dismisses"
                : "↑↓ and 1-9 select · Return continues · Esc dismisses")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            // Action buttons cluster tighter than the hint text.
            HStack(spacing: 4) {
                if questionIndex > 0 {
                    navButton("arrow.left", help: "Previous question (←)") {
                        moveQuestion(-1)
                    }
                }
                if !isLastQuestion {
                    // More questions ahead: advance instead of submitting.
                    navButton("arrow.right", help: "Next question (→)") {
                        moveQuestion(1)
                    }
                } else {
                    // Submit mirrors the composer's send button.
                    Button { submit() } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 28, height: 28)
                            .foregroundStyle(isSubmittable ? theme.windowBackground : Color.secondary.opacity(0.75))
                            .background(
                                Circle().fill(isSubmittable ? Color.primary.opacity(0.82) : Color.secondary.opacity(0.16))
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isSubmittable)
                    .help(isSubmittable ? "Submit answers (↩)" : "\"Other\" needs an answer below")
                }
            }
        }
    }

    private func navButton(
        _ systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(Color.primary)
                .background(Circle().fill(Color.secondary.opacity(0.16)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Behavior

    private func notesBinding(_ question: QuestionSpec) -> Binding<String> {
        Binding(
            get: { notes[question.id] ?? "" },
            set: { notes[question.id] = $0 }
        )
    }

    private func rowCount(_ question: QuestionSpec) -> Int {
        question.options.count + (question.allowsOther ? 1 : 0)
    }

    /// Selecting a row: single-select replaces the choice (Other included);
    /// multi-select toggles.
    private func activate(_ question: QuestionSpec, index: Int) {
        let token = index >= question.options.count ? Self.otherToken : question.options[index].label
        var selected = selections[question.id, default: []]
        if question.multiSelect == true {
            if selected.contains(token) { selected.remove(token) } else { selected.insert(token) }
        } else {
            selected = selected.contains(token) ? [] : [token]
        }
        selections[question.id] = selected
    }

    /// Commits the highlighted row as the single-select choice without toggling
    /// — Return must never clear a row the user already picked (by click, space,
    /// or digit) on its way to advancing. Idempotent, so pressing Return on an
    /// already-selected row keeps it selected.
    private func selectHighlighted(_ question: QuestionSpec, index: Int) {
        let token = index >= question.options.count ? Self.otherToken : question.options[index].label
        selections[question.id] = [token]
    }

    private func moveQuestion(_ delta: Int) {
        let next = questionIndex + delta
        guard request.questions.indices.contains(next) else { return }
        questionIndex = next
        highlighted = 0
        isPickerFocused = true
    }

    private func advanceOrSubmit() {
        if isLastQuestion {
            submit()
        } else {
            moveQuestion(1)
        }
    }

    /// Builds the answers map: selected labels ride as `answers`, the note
    /// rides as `note` (the providers append/merge it appropriately). An
    /// "Other" selection contributes no label — its note IS the answer.
    private func submit() {
        guard isSubmittable else { return }
        var answers: [String: QuestionAnswerEntry] = [:]
        for question in request.questions {
            let selected = selections[question.id, default: []]
            let note = (notes[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let labels = question.options.map(\.label).filter { selected.contains($0) }
            if !labels.isEmpty || !note.isEmpty {
                answers[question.id] = QuestionAnswerEntry(
                    answers: labels,
                    note: note.isEmpty ? nil : note
                )
            }
        }
        Task { await controller.answerQuestion(answers: answers) }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // Only steer while the option list itself has focus. When the notes
        // editor (an NSTextView) is first responder, every key (spaces,
        // digits, arrows) must reach it — SwiftUI's FocusState doesn't
        // reliably clear for AppKit first responders, so check directly.
        // The editor's own keyDown handles Escape back out.
        if NSApp.keyWindow?.firstResponder is NSTextView { return .ignored }
        guard let question else { return .ignored }
        switch press.key {
        case .upArrow:
            highlighted = max(0, highlighted - 1)
            return .handled
        case .downArrow:
            highlighted = min(rowCount(question) - 1, highlighted + 1)
            return .handled
        case .leftArrow:
            moveQuestion(-1)
            return .handled
        case .rightArrow:
            moveQuestion(1)
            return .handled
        case .space:
            activate(question, index: highlighted)
            return .handled
        case .return:
            // Return commits and advances; it must not toggle the highlighted
            // row (that silently drops a selection made by click/space/digit).
            // Single-select picks the highlighted row; multi-select keeps its
            // existing toggles.
            if question.multiSelect != true {
                selectHighlighted(question, index: highlighted)
            }
            advanceOrSubmit()
            return .handled
        case .escape:
            Task { await controller.cancelQuestion() }
            return .handled
        default:
            if let digit = press.characters.first?.wholeNumberValue,
               digit >= 1, digit <= rowCount(question) {
                highlighted = digit - 1
                activate(question, index: digit - 1)
                return .handled
            }
            return .ignored
        }
    }
}
