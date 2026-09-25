import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

/// A blocking agent question as the composer card's content: the composer's
/// one glass card morphs into this while a question is active. Plan approval
/// and first-party setup flows receive dedicated presentations; generic questions show one
/// question at a time, selections and notes accumulated across questions and
/// submitted once.
///
/// Touch-first and progressively disclosed:
/// - Selecting an option never sends it: the answer goes only when the user
///   taps Submit (or Next, for earlier questions). Any free-form field only
///   appears once asked for ("Other", or "Add Note").
/// - The card never outgrows the height it is offered (which shrinks with the
///   keyboard). Header, answer field, and actions stay pinned; only the
///   question and its options scroll, so Submit is always reachable.
/// - Progress shows in place on the Submit button rather than blanketing
///   the card.
struct QuestionCardView: View {
  @Bindable var controller: SessionController
  let request: QuestionRequest
  /// The tallest the card's content may be, already net of the card's
  /// padding. Keyboard-aware: the host re-offers a smaller value as the
  /// keyboard rises.
  let maxHeight: CGFloat

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var questionIndex = 0
  /// Direction of the last page change, so the push transition runs the
  /// way the user navigated.
  @State private var isPagingForward = true
  @State private var selections: [String: Set<String>] = [:]
  @State private var notes: [String: String] = [:]
  /// Questions whose optional note field the user opened.
  @State private var revealedNotes: Set<String> = []
  @State private var headerHeight: CGFloat = 0
  @State private var bottomHeight: CGFloat = 0
  @State private var contentHeight: CGFloat = 0
  @FocusState private var isAnswerFieldFocused: Bool

  /// Sentinel mirroring macOS: the synthetic "Other" row's stored label.
  private static let otherSentinel = "__other__"
  private static let sectionSpacing: CGFloat = 12
  /// Options never collapse below roughly two rows, even with the keyboard up.
  private static let minimumScrollHeight: CGFloat = 96
  /// Below this offered height the full card can't show header, options,
  /// field, and actions together (roughly landscape with the keyboard up).
  private static let compactThreshold: CGFloat = 220

  private var question: QuestionSpec? {
    guard request.questions.indices.contains(questionIndex) else { return nil }
    return request.questions[questionIndex]
  }

  private var isLastQuestion: Bool {
    questionIndex >= request.questions.count - 1
  }

  /// Individual questions may be left unanswered (macOS parity), but there
  /// must be something to send, and a selected "Other" demands its text.
  private var isSubmittable: Bool {
    let hasAnswer = request.questions.contains { spec in
      !(selections[spec.id] ?? []).isEmpty || !trimmedNote(spec).isEmpty
    }
    return hasAnswer
      && request.questions.allSatisfy { spec in
        !isOtherSelected(spec) || !trimmedNote(spec).isEmpty
      }
  }

  @ViewBuilder
  var body: some View {
    if let question, request.questions.count == 1, question.id == QuestionRequest.exitPlanModeId {
      PlanApprovalQuestionCard(controller: controller, question: question, maxHeight: maxHeight)
    } else if let question, question.presentation == .browserChoice {
      BrowserChoiceQuestionCard(controller: controller, question: question)
    } else if let question, isBrowserExtensionPresentation(question) {
      BrowserExtensionQuestionCard(controller: controller, question: question)
    } else {
      genericQuestionCard
    }
  }

  /// Too short for the full card while typing (landscape with the
  /// keyboard up): collapse to one Messages-style row — the answer field
  /// and its action. Dismissing the keyboard restores the card. Decided
  /// from the offered height alone, never from measured chrome, so the
  /// switch cannot oscillate.
  private var isCompactWhileTyping: Bool {
    isAnswerFieldFocused && maxHeight < Self.compactThreshold
  }

  private var genericQuestionCard: some View {
    VStack(alignment: .leading, spacing: Self.sectionSpacing) {
      if !isCompactWhileTyping {
        header
        if let question {
          questionPage(question)
            .id(question.id)
            .transition(pageTransition)
        }
      }

      // AnyLayout keeps the field's identity (and so its focus and the
      // keyboard) when the row collapses or expands.
      let bottomLayout =
        isCompactWhileTyping
        ? AnyLayout(HStackLayout(alignment: .bottom, spacing: 10))
        : AnyLayout(VStackLayout(alignment: .leading, spacing: Self.sectionSpacing))
      bottomLayout {
        if isCompactWhileTyping {
          // The way back to the full card (and its options).
          Button {
            isAnswerFieldFocused = false
          } label: {
            Image(systemName: "keyboard.chevron.compact.down")
              .composerCircleActionLabel(.secondary)
          }
          .buttonStyle(.plain)
          .pointerHighlight(Circle())
          .accessibilityLabel("Show all options")
        }
        if let question, showsAnswerField(question) {
          // One field per question: reusing it across pages let the
          // Return that advanced re-apply to the next question.
          answerField(question)
            .id(question.id)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        if isCompactWhileTyping {
          primaryButton
        } else {
          footer
        }
      }
      .onGeometryChange(for: CGFloat.self) {
        $0.size.height
      } action: {
        bottomHeight = $0
      }
      // The compact row has no scroll view for the system's interactive
      // dismissal to ride on; a downward swipe on it does the same job.
      .simultaneousGesture(
        DragGesture(minimumDistance: 12).onEnded { value in
          guard isCompactWhileTyping, value.translation.height > 24 else { return }
          isAnswerFieldFocused = false
        }
      )
    }
    .animation(Motion.quick(reduceMotion: reduceMotion), value: questionIndex)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: selections)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: revealedNotes)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: isCompactWhileTyping)
    .sensoryFeedback(.selection, trigger: selections)
    .sensoryFeedback(.selection, trigger: questionIndex)
  }

  /// The question is the header, pinned above the options so it stays in
  /// view while they scroll (clamped to two lines while typing).
  private var header: some View {
    QuestionCardHeader(
      title: question?.question ?? "",
      lineLimit: isAnswerFieldFocused ? 2 : nil,
      dismissLabel: "Dismiss question",
      onDismiss: { Task { await controller.cancelQuestion() } }
    )
    .onGeometryChange(for: CGFloat.self) {
      $0.size.height
    } action: {
      headerHeight = $0
    }
  }

  private var pageTransition: AnyTransition {
    guard !reduceMotion else { return .opacity }
    return .push(from: isPagingForward ? .trailing : .leading)
  }

  private func isBrowserExtensionPresentation(_ spec: QuestionSpec) -> Bool {
    spec.presentation == .browserExtensionSetup
      || spec.presentation == .browserExtensionWaiting
  }

  // MARK: - Question page

  /// What remains for the scrolling region once pinned chrome is placed.
  private var scrollBudget: CGFloat {
    let chrome = headerHeight + bottomHeight + Self.sectionSpacing * 2
    return max(Self.minimumScrollHeight, maxHeight - chrome)
  }

  /// The prompt and its options, in a scroll view sized to its content up
  /// to the budget: short questions sit at their natural height, taller
  /// ones scroll within it. The content's height never depends on the
  /// frame, so measuring it cannot feed back into layout. (A `ViewThatFits`
  /// here re-lays out every row per alignment query and hung the app.)
  private func questionPage(_ spec: QuestionSpec) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        questionContent(spec)
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            contentHeight = $0
          }
      }
      // While typing, the options always take drags — even when they fit —
      // so a downward swipe tracks the keyboard closed (the native
      // interactive dismissal) and the list can be scrolled.
      .scrollBounceBehavior(isAnswerFieldFocused ? .always : .basedOnSize)
      .scrollEdgeEffectStyle(.soft, for: .vertical)
      .scrollDismissesKeyboard(.interactively)
      // When the keyboard squeezes the options, keep the choice being
      // typed about ("Other", or the annotated option) in view.
      .onChange(of: scrollBudget) {
        guard isAnswerFieldFocused, let target = focusedOptionID(spec) else { return }
        withAnimation(Motion.quick(reduceMotion: reduceMotion)) {
          proxy.scrollTo(target, anchor: .bottom)
        }
      }
    }
    // A ceiling, not a fixed height: the region yields space before the
    // pinned header, answer field, and actions do.
    .frame(minHeight: min(contentHeight, Self.minimumScrollHeight), maxHeight: min(contentHeight, scrollBudget))
    .layoutPriority(-1)
  }

  private func focusedOptionID(_ spec: QuestionSpec) -> String? {
    if isOtherSelected(spec) { return Self.otherSentinel }
    return spec.options.last { isSelected($0.label, in: spec) }?.label
  }

  private func questionContent(_ spec: QuestionSpec) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      if let message = request.message, !message.isEmpty, questionIndex == 0 {
        Text(message)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      VStack(spacing: 8) {
        ForEach(spec.options) { option in
          QuestionOptionRow(
            title: option.label,
            description: option.description,
            indicator: spec.multiSelect == true ? .multiple : .single,
            isSelected: isSelected(option.label, in: spec),
            action: { activate(option.label, spec: spec) }
          )
          .id(option.label)
        }
        if spec.allowsOther == true {
          QuestionOptionRow(
            title: "Other",
            description: nil,
            indicator: spec.multiSelect == true ? .multiple : .single,
            isSelected: isOtherSelected(spec),
            action: { activate(Self.otherSentinel, spec: spec) }
          )
          .accessibilityHint("Type your own answer")
          .id(Self.otherSentinel)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func isSelected(_ label: String, in spec: QuestionSpec) -> Bool {
    (selections[spec.id] ?? []).contains(label)
  }

  private func isOtherSelected(_ spec: QuestionSpec) -> Bool {
    isSelected(Self.otherSentinel, in: spec)
  }

  /// Toggle in multi-select, replace otherwise. Selecting only marks the
  /// answer; sending is always an explicit Submit.
  private func activate(_ label: String, spec: QuestionSpec) {
    var set = selections[spec.id] ?? []
    if spec.multiSelect == true {
      if set.contains(label) { set.remove(label) } else { set.insert(label) }
    } else {
      set = set.contains(label) ? [] : [label]
    }
    selections[spec.id] = set
    // Choosing "Other" is asking to type: bring the keyboard with it.
    // Backing out of it discards that answer rather than silently
    // turning it into a note.
    if label == Self.otherSentinel {
      isAnswerFieldFocused = set.contains(label)
      if !set.contains(label), !revealedNotes.contains(spec.id) {
        notes[spec.id] = nil
      }
    }
  }

  // MARK: - Answer field

  /// "Other" needs its text; otherwise a note is opt-in via "Add Note" and
  /// stays open while it has content.
  private func showsAnswerField(_ spec: QuestionSpec) -> Bool {
    isOtherSelected(spec) || revealedNotes.contains(spec.id) || !trimmedNote(spec).isEmpty
  }

  private func trimmedNote(_ spec: QuestionSpec) -> String {
    (notes[spec.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func answerField(_ spec: QuestionSpec) -> some View {
    let otherSelected = isOtherSelected(spec)
    let shape = ComposerCardStyle().insetShape(by: ComposerCardStyle.contentPadding)
    // The compact row hides the card, so its placeholder carries the
    // question for context.
    let prompt =
      isCompactWhileTyping ? spec.question : (otherSelected ? "Your answer" : "Add a note for the agent")
    return TextField(
      prompt,
      text: Binding(
        get: { notes[spec.id] ?? "" },
        set: { newValue in
          // A vertical field turns Return into a newline; answers are
          // short, so Return means "done" instead — never a trap
          // behind the keyboard.
          guard newValue.contains("\n") else {
            notes[spec.id] = newValue
            return
          }
          notes[spec.id] = newValue.replacingOccurrences(of: "\n", with: "")
          // UIKit can report the same Return twice; only the field's own
          // page may act on it, or one press would skip a question.
          guard question?.id == spec.id else { return }
          handleReturn()
        }
      ),
      axis: .vertical
    )
    .font(.body)
    .lineLimit(1...4)
    .focused($isAnswerFieldFocused)
    .submitLabel(isLastQuestion ? .send : .next)
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(minHeight: 48)
    .background(shape.fill(HierarchicalShapeStyle.quaternary.opacity(0.6)))
    .accessibilityLabel(otherSelected ? "Your answer" : "Note")
  }

  /// Return advances to the next question, or submits on the last one
  /// (falling back to dismissing the keyboard when there's nothing valid
  /// to send yet).
  private func handleReturn() {
    if !isLastQuestion {
      page(by: 1)
    } else if isSubmittable, !controller.isResolvingQuestion {
      submitCollected()
    } else {
      isAnswerFieldFocused = false
    }
  }

  // MARK: - Footer

  @ViewBuilder
  private var footer: some View {
    if let question {
      HStack(spacing: 14) {
        backButton(question)
        if !showsAnswerField(question) {
          Button {
            revealedNotes.insert(question.id)
            isAnswerFieldFocused = true
          } label: {
            Label("Add Note", systemImage: "text.bubble")
              .font(.subheadline.weight(.medium))
              .padding(.horizontal, 12)
              .frame(minHeight: 30)
              .background(Capsule().fill(Color.secondary.opacity(0.16)))
              .expandedHitTarget(base: 30)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .pointerHighlight(Capsule())
        }
        Spacer(minLength: 0)
        primaryButton
      }
    }
  }

  @ViewBuilder
  private func backButton(_ spec: QuestionSpec) -> some View {
    if let backLabel = spec.backOptionLabel {
      // A provider-supplied back action answers directly.
      Button {
        submit([spec.id: QuestionAnswerEntry(answers: [backLabel])])
      } label: {
        Image(systemName: "chevron.left")
          .composerCircleActionLabel(.secondary)
      }
      .buttonStyle(.plain)
      .pointerHighlight(Circle())
      .accessibilityLabel(backLabel)
    } else if questionIndex > 0 {
      Button {
        page(by: -1)
      } label: {
        Image(systemName: "chevron.left")
          .composerCircleActionLabel(.secondary)
      }
      .buttonStyle(.plain)
      .pointerHighlight(Circle())
      .accessibilityLabel("Previous question")
    }
  }

  @ViewBuilder
  private var primaryButton: some View {
    if isLastQuestion {
      let canSubmit = isSubmittable && !controller.isResolvingQuestion
      Button {
        submitCollected()
      } label: {
        Group {
          if controller.isResolvingQuestion {
            ProgressView()
              .controlSize(.small)
              .tint(.white)
          } else {
            Image(systemName: "arrow.up")
          }
        }
        .composerCircleActionLabel(.primary, isEnabled: canSubmit || controller.isResolvingQuestion)
      }
      .buttonStyle(.plain)
      .pointerHighlight(Circle())
      .disabled(!canSubmit)
      .accessibilityLabel(controller.isResolvingQuestion ? "Submitting answers" : "Submit answers")
    } else {
      Button {
        page(by: 1)
      } label: {
        Image(systemName: "arrow.right")
          .composerCircleActionLabel(.primary)
      }
      .buttonStyle(.plain)
      .pointerHighlight(Circle())
      .accessibilityLabel("Next question")
    }
  }

  private func page(by delta: Int) {
    isPagingForward = delta > 0
    isAnswerFieldFocused = false
    questionIndex = min(max(0, questionIndex + delta), request.questions.count - 1)
  }

  // MARK: - Submit

  /// Builds one entry per answered question: real labels as answers and
  /// the typed text as the note (macOS parity) — except a lone "Other",
  /// whose text is the answer itself.
  private func submitCollected() {
    var entries: [String: QuestionAnswerEntry] = [:]
    for spec in request.questions {
      let labels = (selections[spec.id] ?? []).subtracting([Self.otherSentinel])
      let note = trimmedNote(spec)
      guard !labels.isEmpty || !note.isEmpty else { continue }
      entries[spec.id] =
        if isOtherSelected(spec), labels.isEmpty {
          QuestionAnswerEntry(answers: [note])
        } else {
          QuestionAnswerEntry(answers: Array(labels), note: note.isEmpty ? nil : note)
        }
    }
    guard !entries.isEmpty else { return }
    submit(entries)
  }

  private func submit(_ entries: [String: QuestionAnswerEntry]) {
    isAnswerFieldFocused = false
    Task { await controller.answerQuestion(answers: entries) }
  }
}
