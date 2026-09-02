import SwiftUI
import AppKit
import CodevisorCore
import ACPKit
import CodevisorUI

// MARK: - Behavior

extension QuestionPickerContent {
    func notesBinding(_ question: QuestionSpec) -> Binding<String> {
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
    func activate(_ question: QuestionSpec, index: Int) {
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

    func moveQuestion(_ delta: Int) {
        let next = questionIndex + delta
        guard request.questions.indices.contains(next) else { return }
        questionIndex = next
        highlighted = 0
        focusPicker()
    }

    /// Puts AppKit first responder on the option list's key anchor — the
    /// picker's one focus writer besides the session focus controller.
    func focusPicker() {
        guard let view = anchor.view else { return }
        view.window?.makeFirstResponder(view)
    }

    /// Puts first responder in the notes editor — "Other" makes it the
    /// answer field, so selecting Other hands the keyboard straight there.
    func focusNotes() {
        guard let view = anchor.notesEditor else { return }
        view.window?.makeFirstResponder(view)
    }

    func advanceOrSubmit() {
        if isLastQuestion {
            submit()
        } else {
            moveQuestion(1)
        }
    }

    /// Builds the answers map: selected labels ride as `answers`, the note
    /// rides as `note` (the providers append/merge it appropriately). An
    /// "Other" selection contributes no label — its note IS the answer.
    func submit() {
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

    func cancel() {
        guard !isResolving else { return }
        didStartResolving = true
        Task {
            await controller.cancelQuestion()
            didStartResolving = false
        }
    }

    /// Internal setup flows can expose deterministic navigation without
    /// pretending Back is one of the user's answer choices.
    func submitDirectAnswer(_ question: QuestionSpec, label: String) {
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
    func handleKey(_ key: QuestionPickerKey) -> Bool {
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
        if !canInstallBrowserExtensionLocally {
            switch key {
            case .enter, .space, .left:
                if let backOptionLabel = question.backOptionLabel {
                    submitDirectAnswer(question, label: backOptionLabel)
                }
                return true
            case .escape:
                cancel()
                return true
            case .right, .up, .down, .digit:
                return true
            }
        }
        switch key {
        case .enter, .space:
            if !didOpenBrowserExtensions {
                performBrowserSetupAction("Open Extensions")
            }
            return true
        case .left:
            if didOpenBrowserExtensions {
                showBrowserExtensionDragStage(false)
            } else if let backOptionLabel = question.backOptionLabel {
                submitDirectAnswer(question, label: backOptionLabel)
            }
            return true
        case .right:
            if !didOpenBrowserExtensions {
                showBrowserExtensionDragStage(true)
            }
            return true
        case .escape:
            cancel()
            return true
        case .up, .down, .digit:
            return true
        }
    }
}
