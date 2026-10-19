import SwiftUI
import AppKit
import CodevisorCore
import ACPKit
import CodevisorUI

struct QuestionPickerContent: View {
  @Bindable var controller: SessionController
  let request: QuestionRequest
  @Binding var didStartResolving: Bool
  var focus: TerminalFocusController? = nil
  var chatId: UUID? = nil

  static let otherToken = "__other__"

  @State var questionIndex = 0
  @State var selections: [String: Set<String>] = [:]
  @State var notes: [String: String] = [:]
  @State var notesHeight: CGFloat = 24
  @State var highlighted = 0
  @State var infoOption: String?
  @State var revealedNotes: Set<String> = []
  @State var didOpenBrowserExtensions = false
  @State var anchor = AnchorBox()

  final class AnchorBox {
    weak var view: QuestionPickerKeyView?
    weak var notesEditor: SubmittingTextView?
    var focusesNotesWhenReady = false
  }

  var question: QuestionSpec? {
    request.questions.indices.contains(questionIndex) ? request.questions[questionIndex] : nil
  }

  var isLastQuestion: Bool { questionIndex >= request.questions.count - 1 }

  var isResolving: Bool { didStartResolving || controller.isResolvingQuestion }

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
          if showsNoteField(question) {
            noteField(question)
          }
          footer(question)
        }
      }
    }
    .disabled(isResolving)
    .background(
      QuestionPickerFocusAnchor(
        onAttach: { view in
          anchor.view = view
          if let focus, let chatId {
            focus.registerQuestionPicker(view, forChat: chatId)
          } else {
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
      infoOption = nil
      revealedNotes = []
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

  func isBrowserExtensionPresentation(_ question: QuestionSpec) -> Bool {
    question.presentation == .browserExtensionSetup
      || question.presentation == .browserExtensionWaiting
  }

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
