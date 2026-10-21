import ACPKit
import CodevisorCore
import CodevisorUI
import SwiftUI

struct QuestionCardView: View {
  @Bindable var controller: SessionController
  let request: QuestionRequest
  let maxHeight: CGFloat

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var questionIndex = 0
  @State private var isPagingForward = true
  @State private var selections: [String: Set<String>] = [:]
  @State private var notes: [String: String] = [:]
  @State private var revealedNotes: Set<String> = []
  @State private var headerHeight: CGFloat = 0
  @State private var bottomHeight: CGFloat = 0
  @State private var contentHeight: CGFloat = 0
  @FocusState private var isAnswerFieldFocused: Bool

  private static let otherSentinel = "__other__"
  private static let sectionSpacing: CGFloat = 12
  private static let minimumScrollHeight: CGFloat = 96
  private static let compactThreshold: CGFloat = 220

  private var question: QuestionSpec? {
    guard request.questions.indices.contains(questionIndex) else { return nil }
    return request.questions[questionIndex]
  }

  private var isLastQuestion: Bool {
    questionIndex >= request.questions.count - 1
  }

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
    } else {
      genericQuestionCard
    }
  }

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

      let bottomLayout =
        isCompactWhileTyping
        ? AnyLayout(HStackLayout(alignment: .bottom, spacing: 10))
        : AnyLayout(VStackLayout(alignment: .leading, spacing: Self.sectionSpacing))
      bottomLayout {
        if isCompactWhileTyping {
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

  private var scrollBudget: CGFloat {
    let chrome = headerHeight + bottomHeight + Self.sectionSpacing * 2
    return max(Self.minimumScrollHeight, maxHeight - chrome)
  }

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
      .scrollBounceBehavior(isAnswerFieldFocused ? .always : .basedOnSize)
      .scrollEdgeEffectStyle(.soft, for: .vertical)
      .scrollDismissesKeyboard(.interactively)
      .onChange(of: scrollBudget) {
        guard isAnswerFieldFocused, let target = focusedOptionID(spec) else { return }
        withAnimation(Motion.quick(reduceMotion: reduceMotion)) {
          proxy.scrollTo(target, anchor: .bottom)
        }
      }
    }
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

  private func activate(_ label: String, spec: QuestionSpec) {
    var set = selections[spec.id] ?? []
    if spec.multiSelect == true {
      if set.contains(label) { set.remove(label) } else { set.insert(label) }
    } else {
      set = set.contains(label) ? [] : [label]
    }
    selections[spec.id] = set
    if label == Self.otherSentinel {
      isAnswerFieldFocused = set.contains(label)
      if !set.contains(label), !revealedNotes.contains(spec.id) {
        notes[spec.id] = nil
      }
    }
  }

  private func showsAnswerField(_ spec: QuestionSpec) -> Bool {
    isOtherSelected(spec) || revealedNotes.contains(spec.id) || !trimmedNote(spec).isEmpty
  }

  private func trimmedNote(_ spec: QuestionSpec) -> String {
    (notes[spec.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func answerField(_ spec: QuestionSpec) -> some View {
    let otherSelected = isOtherSelected(spec)
    let shape = ComposerCardStyle().insetShape(by: ComposerCardStyle.contentPadding)
    let prompt =
      isCompactWhileTyping ? spec.question : (otherSelected ? "Your answer" : "Add a note for the agent")
    return TextField(
      prompt,
      text: Binding(
        get: { notes[spec.id] ?? "" },
        set: { newValue in
          guard newValue.contains("\n") else {
            notes[spec.id] = newValue
            return
          }
          notes[spec.id] = newValue.replacingOccurrences(of: "\n", with: "")
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

  private func handleReturn() {
    if !isLastQuestion {
      page(by: 1)
    } else if isSubmittable, !controller.isResolvingQuestion {
      submitCollected()
    } else {
      isAnswerFieldFocused = false
    }
  }

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
              .capsuleActionLabel()
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
