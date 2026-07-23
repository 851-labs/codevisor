import SwiftUI
import AppKit
import CodevisorCore
import ACPKit

/// The question-mode content hosted by `ComposerCard`. This view intentionally
/// owns no background, border, padding, or transition: those belong to the
/// shared composer shell so every state receives the same Liquid Glass style.
///
/// Generic questions use the normal option-and-note picker. First-party setup
/// flows can request a dedicated presentation while retaining the same
/// blocking question lifecycle, keyboard focus, cancellation, and resolution.
///
/// Multiple questions show one at a time with progress; answers accumulate
/// locally and submit once after the last question (codex behavior).
struct QuestionPickerContent: View {
    @Environment(\.theme) private var theme
    @Bindable var controller: SessionController
    let request: QuestionRequest
    /// Set synchronously in the key/button handler, before the async Task gets
    /// its first main-actor turn, so Return always produces immediate feedback.
    @Binding var didStartResolving: Bool
    /// The session's AppKit focus controller and this chat's id: the key
    /// anchor registers here so the picker takes first responder through the
    /// same reliable `makeFirstResponder`-with-retry path as the composer
    /// text view. Nil (previews, standalone composers) falls back to a
    /// best-effort local grab.
    var focus: TerminalFocusController? = nil
    var chatId: UUID? = nil

    /// Sentinel stored in `selections` when the "Other" row is chosen.
    private static let otherToken = "__other__"

    @State private var questionIndex = 0
    /// Accumulated selections per question id (option labels + otherToken).
    @State private var selections: [String: Set<String>] = [:]
    /// Notes per question id — supplementary for options, the answer for Other.
    @State private var notes: [String: String] = [:]
    @State private var notesHeight: CGFloat = 24
    @State private var highlighted = 0
    /// Weak handles to the picker's AppKit focus targets: the key anchor
    /// (option list) and the notes editor's text view, so explicit moves —
    /// question navigation, Escape out of the notes editor, option clicks,
    /// Return on "Other" — can place first responder directly. A class box
    /// because the views report themselves from AppKit callbacks, not view
    /// updates.
    @State private var anchor = AnchorBox()

    final class AnchorBox {
        weak var view: QuestionPickerKeyView?
        weak var notesEditor: SubmittingTextView?
    }

    private var question: QuestionSpec? {
        request.questions.indices.contains(questionIndex) ? request.questions[questionIndex] : nil
    }

    private var isLastQuestion: Bool { questionIndex >= request.questions.count - 1 }

    private var isResolving: Bool {
        didStartResolving || controller.isResolvingQuestion
    }

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
                if isBrowserExtensionPresentation(question) {
                    browserExtensionSetup(question)
                } else {
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
        }
        .disabled(isResolving)
        // AppKit keyboard anchor instead of SwiftUI focus: `@FocusState`
        // assignments are dropped during the composer card's animated state
        // swap (see QuestionPickerFocusAnchor), which left the picker deaf
        // to arrows/Escape until a click handed it focus.
        .background(
            QuestionPickerFocusAnchor(
                onAttach: { view in
                    anchor.view = view
                    if let focus, let chatId {
                        focus.registerQuestionPicker(view, forChat: chatId)
                    } else {
                        // Standalone composer (previews): best-effort grab.
                        view.window?.makeFirstResponder(view)
                    }
                },
                onKey: { handleKey($0) },
                onDetach: { view in
                    if let focus, let chatId {
                        focus.unregisterQuestionPicker(view, forChat: chatId)
                    }
                }
            )
        )
        .onAppear {
            highlighted = 0
        }
        .onChange(of: request.questionId) { _, _ in
            questionIndex = 0
            selections = [:]
            notes = [:]
            highlighted = 0
            didStartResolving = false
            focusPicker()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent question")
    }

    // MARK: - Sections

    private func isBrowserExtensionPresentation(_ question: QuestionSpec) -> Bool {
        question.presentation == .browserExtensionSetup
            || question.presentation == .browserExtensionWaiting
    }

    private func browserExtensionSetup(_ question: QuestionSpec) -> some View {
        let isWaiting = question.presentation == .browserExtensionWaiting
        let isDevelopment = question.options.contains(where: { $0.label == "Show Folder" })
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Add Codevisor to Chrome")
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 12)
                dismissButton
            }

            VStack(alignment: .leading, spacing: 0) {
                if isDevelopment {
                    browserSetupStep(
                        number: 1,
                        title: "Open the Extensions page in Chrome",
                        actionLabel: "Open Extensions",
                        systemImage: "macwindow"
                    )
                    browserSetupDivider
                    browserSetupStep(
                        number: 2,
                        title: "Open the Codevisor extension folder",
                        actionLabel: "Show Folder",
                        systemImage: "folder"
                    )
                    browserSetupDivider
                    browserSetupStep(
                        number: 3,
                        title: "Drop the extension folder into the Extensions page"
                    )
                } else {
                    browserSetupStep(
                        number: 1,
                        title: "Install Codevisor from the Chrome Web Store",
                        actionLabel: "Open Web Store",
                        systemImage: "arrow.up.forward.app"
                    )
                    browserSetupDivider
                    browserSetupStep(
                        number: 2,
                        title: "Return to Codevisor after the extension is installed"
                    )
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.cardQuietBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            )

            HStack(spacing: 8) {
                if isWaiting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for Chrome…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let backOptionLabel = question.backOptionLabel {
                    navButton("arrow.left", help: "Back") {
                        submitDirectAnswer(question, label: backOptionLabel)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isWaiting ? "Finish Chrome setup" : "Connect Chrome")
    }

    @ViewBuilder
    private func browserSetupStep(
        number: Int,
        title: String,
        actionLabel: String? = nil,
        systemImage: String? = nil
    ) -> some View {
        HStack(spacing: 10) {
            Text("\(number).")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            Text(title)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            if let actionLabel, let systemImage {
                Button {
                    performBrowserSetupAction(actionLabel)
                } label: {
                    Label(actionLabel, systemImage: systemImage)
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var browserSetupDivider: some View {
        Divider()
            .padding(.leading, 40)
    }

    private func performBrowserSetupAction(_ action: String) {
        Task {
            await controller.performBrowserExtensionSetupAction(action)
        }
    }

    private var dismissButton: some View {
        Button {
            cancel()
        } label: {
            Image(systemName: "xmark")
                .font(.caption)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Dismiss without answering (Esc)")
        .accessibilityLabel("Dismiss without answering")
        .accessibilityHint("Keyboard shortcut: Escape")
    }

    private func header(_ question: QuestionSpec) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(question.question)
                .font(.callout.weight(.medium))
            Spacer(minLength: 0)
            dismissButton
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
            // Mouse interaction makes the picker the keyboard target too,
            // so a follow-up Return/arrow works no matter where focus was.
            // Choosing "Other" goes straight to its answer field instead.
            if index >= question.options.count,
               selections[question.id, default: []].contains(Self.otherToken) {
                focusNotes()
            } else {
                focusPicker()
            }
        } label: {
            // Same selection language as the slash-command menu in this
            // card: the keyboard highlight is an accent pill with white
            // content; a committed selection that ISN'T highlighted keeps a
            // quiet themed fill (multi-select stays legible at a glance)
            // with an accent checkmark.
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(
                        isHighlighted ? AnyShapeStyle(.white)
                            : isSelected ? AnyShapeStyle(theme.accent) : AnyShapeStyle(.tertiary)
                    )
                Text(label)
                    .fontWeight(.medium)
                if let description, !description.isEmpty {
                    Text(description)
                        .lineLimit(1)
                        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 0)
                if index < 9 {
                    Text("\(index + 1)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.quaternary))
                }
            }
            .foregroundStyle(isHighlighted ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isHighlighted ? AnyShapeStyle(theme.accent)
                            : isSelected ? AnyShapeStyle(theme.rowSelectedBackground)
                            : AnyShapeStyle(Color.clear)
                    )
            )
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
                        focusPicker()
                        return true
                    }
                    return false
                },
                onTextViewReady: { textView in
                    anchor.notesEditor = textView
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
        // Themed input-field chrome: quiet card fill on the glass, themed
        // border — accented while "Other" makes this field the answer.
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardQuietBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isOtherSelected ? theme.accent : theme.border,
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
                if let backOptionLabel = question.backOptionLabel {
                    navButton("arrow.left", help: "Back") {
                        submitDirectAnswer(question, label: backOptionLabel)
                    }
                }
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
                    ComposerSubmitButton(
                        isEnabled: isSubmittable,
                        help: isSubmittable
                            ? "Submit answers (↩)"
                            : "\"Other\" needs an answer below",
                        accessibilityLabel: "Submit answers"
                    ) {
                        submit()
                    }
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
                .frame(width: 26, height: 26)
                .foregroundStyle(Color.primary)
                .background(Circle().fill(Color.secondary.opacity(0.16)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
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
        focusPicker()
    }

    /// Puts AppKit first responder on the option list's key anchor — the
    /// picker's one focus writer besides the session focus controller.
    private func focusPicker() {
        guard let view = anchor.view else { return }
        view.window?.makeFirstResponder(view)
    }

    /// Puts first responder in the notes editor — "Other" makes it the
    /// answer field, so selecting Other hands the keyboard straight there.
    private func focusNotes() {
        guard let view = anchor.notesEditor else { return }
        view.window?.makeFirstResponder(view)
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
        guard isSubmittable, !isResolving else { return }
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
        didStartResolving = true
        Task {
            await controller.answerQuestion(answers: answers)
            // On success this view unmounts. On failure the pending request is
            // still present, so reveal the intact local selections for retry.
            didStartResolving = false
        }
    }

    private func cancel() {
        guard !isResolving else { return }
        didStartResolving = true
        Task {
            await controller.cancelQuestion()
            didStartResolving = false
        }
    }

    /// Internal setup flows can expose deterministic navigation without
    /// pretending Back is one of the user's answer choices.
    private func submitDirectAnswer(_ question: QuestionSpec, label: String) {
        guard !isResolving else { return }
        didStartResolving = true
        Task {
            await controller.answerQuestion(answers: [
                question.id: QuestionAnswerEntry(answers: [label])
            ])
            didStartResolving = false
        }
    }

    /// Keys arrive through the anchor's first-responder status, so the
    /// responder chain already arbitrates: while the notes editor (an
    /// NSTextView) holds the keyboard, nothing lands here — no manual
    /// first-responder checks needed. The editor's own keyDown handles
    /// Escape back out.
    private func handleKey(_ key: QuestionPickerKey) -> Bool {
        if isResolving { return true }
        guard let question else { return false }
        if isBrowserExtensionPresentation(question) {
            return handleBrowserExtensionKey(key, question: question)
        }
        switch key {
        case .up:
            highlighted = max(0, highlighted - 1)
            return true
        case .down:
            highlighted = min(rowCount(question) - 1, highlighted + 1)
            return true
        case .left:
            if let backOptionLabel = question.backOptionLabel {
                submitDirectAnswer(question, label: backOptionLabel)
            } else {
                moveQuestion(-1)
            }
            return true
        case .right:
            moveQuestion(1)
            return true
        case .space:
            activate(question, index: highlighted)
            return true
        case .enter:
            // Return commits and advances; it must not toggle the highlighted
            // row (that silently drops a selection made by click/space/digit).
            // Single-select picks the highlighted row; multi-select keeps its
            // existing toggles.
            if question.multiSelect != true {
                selectHighlighted(question, index: highlighted)
            }
            // "Other" makes the notes editor the answer field: while its
            // note is still empty, Return hands focus there instead of
            // advancing past an unanswered question. Once a note exists,
            // Return advances as usual.
            let selected = selections[question.id, default: []]
            let note = (notes[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if selected.contains(Self.otherToken), note.isEmpty {
                focusNotes()
                return true
            }
            advanceOrSubmit()
            return true
        case .escape:
            cancel()
            return true
        case .digit(let digit):
            guard digit >= 1, digit <= rowCount(question) else { return false }
            highlighted = digit - 1
            activate(question, index: digit - 1)
            return true
        }
    }

    private func handleBrowserExtensionKey(_ key: QuestionPickerKey, question: QuestionSpec) -> Bool {
        switch key {
        case .enter, .space:
            guard let label = question.options.first?.label else { return true }
            performBrowserSetupAction(label)
            return true
        case .left:
            if let backOptionLabel = question.backOptionLabel {
                submitDirectAnswer(question, label: backOptionLabel)
            }
            return true
        case .escape:
            cancel()
            return true
        case .up, .down, .right, .digit:
            return true
        }
    }
}
