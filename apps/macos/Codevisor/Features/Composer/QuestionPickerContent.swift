import SwiftUI
import AppKit
import CodevisorCore
import ACPKit
import CodevisorUI

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
    @Environment(\.theme) var theme
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
    static let otherToken = "__other__"

    @State var questionIndex = 0
    /// Accumulated selections per question id (option labels + otherToken).
    @State var selections: [String: Set<String>] = [:]
    /// Notes per question id — supplementary for options, the answer for Other.
    @State var notes: [String: String] = [:]
    @State var notesHeight: CGFloat = 24
    @State var highlighted = 0
    @State var didOpenBrowserExtensions = false
    /// Weak handles to the picker's AppKit focus targets: the key anchor
    /// (option list) and the notes editor's text view, so explicit moves —
    /// question navigation, Escape out of the notes editor, option clicks,
    /// Return on "Other" — can place first responder directly. A class box
    /// because the views report themselves from AppKit callbacks, not view
    /// updates.
    @State var anchor = AnchorBox()

    final class AnchorBox {
        weak var view: QuestionPickerKeyView?
        weak var notesEditor: SubmittingTextView?
    }

    var question: QuestionSpec? {
        request.questions.indices.contains(questionIndex) ? request.questions[questionIndex] : nil
    }

    var isLastQuestion: Bool { questionIndex >= request.questions.count - 1 }

    var isResolving: Bool { didStartResolving || controller.isResolvingQuestion }

    /// "Other" needs its note text. Generic questions may be unanswered
    /// (codex-style), while browser choice is an explicit navigation step.
    var isSubmittable: Bool {
        request.questions.allSatisfy { question in
            let selected = selections[question.id, default: []]
            let note = (notes[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let hasValidOther = !selected.contains(Self.otherToken) || !note.isEmpty
            let hasBrowserChoice = question.presentation != .browserChoice || !selected.isEmpty
            return hasValidOther && hasBrowserChoice
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
                    if question.presentation != .browserChoice {
                        notesEditor(question)
                    }
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
            didOpenBrowserExtensions = false
            didStartResolving = false
            focusPicker()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent question")
    }

    // MARK: - Sections

    func isBrowserExtensionPresentation(_ question: QuestionSpec) -> Bool {
        question.presentation == .browserExtensionSetup
            || question.presentation == .browserExtensionWaiting
    }

    /// Chrome setup can manipulate AppKit and Chrome only when this app owns
    /// the server running the chat. Remote machines keep the same durable
    /// question, but render a handoff that the host Mac can finish.
    var canInstallBrowserExtensionLocally: Bool {
        controller.project.serverId == CodevisorMachine.local.id
    }

    private func browserExtensionSetup(_ question: QuestionSpec) -> some View {
        BrowserExtensionQuestionContent(
            controller: controller,
            question: question,
            canInstallLocally: canInstallBrowserExtensionLocally,
            didOpenBrowserExtensions: $didOpenBrowserExtensions,
            cancel: { cancel() },
            submitBack: { submitDirectAnswer(question, label: $0) },
            performSetupAction: performBrowserSetupAction,
            showDragStage: showBrowserExtensionDragStage
        )
    }

    func performBrowserSetupAction(_ action: String) {
        if action == "Open Extensions" {
            showBrowserExtensionDragStage(true)
        }
        Task {
            await controller.performBrowserExtensionSetupAction(action)
        }
    }

    func showBrowserExtensionDragStage(_ isVisible: Bool) {
        didOpenBrowserExtensions = isVisible
        focusPicker()
    }
}
