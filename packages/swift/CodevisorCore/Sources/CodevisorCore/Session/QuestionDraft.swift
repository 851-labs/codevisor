import ACPKit
import Foundation
import Observation

@MainActor
@Observable
public final class QuestionDraft {
  public static let otherToken = "__other__"
  static let autoAdvanceDelay: Duration = .milliseconds(250)

  public let request: QuestionRequest
  public private(set) var page = 0
  public private(set) var isPagingForward = true
  public private(set) var selections: [String: Set<String>] = [:]
  public private(set) var typedAnswers: [String: String] = [:]

  public init(request: QuestionRequest) {
    self.request = request
  }

  public var question: QuestionSpec? {
    request.questions.indices.contains(page) ? request.questions[page] : nil
  }

  public var pageCount: Int { request.questions.count }

  public var isLastPage: Bool { page >= pageCount - 1 }

  public var isSubmittable: Bool {
    hasAnyAnswer && request.questions.allSatisfy { !isOtherSelected($0) || !trimmedTypedAnswer($0).isEmpty }
  }

  public var answers: [String: QuestionAnswerEntry] {
    request.questions.reduce(into: [:]) { entries, spec in
      entries[spec.id] = answer(for: spec)
    }
  }

  public func isSelected(_ label: String, in spec: QuestionSpec) -> Bool {
    selections[spec.id, default: []].contains(label)
  }

  public func isOtherSelected(_ spec: QuestionSpec) -> Bool {
    isSelected(Self.otherToken, in: spec)
  }

  public func typedAnswer(for spec: QuestionSpec) -> String {
    typedAnswers[spec.id] ?? ""
  }

  public func trimmedTypedAnswer(_ spec: QuestionSpec) -> String {
    typedAnswer(for: spec).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func setTypedAnswer(_ text: String, for spec: QuestionSpec) {
    typedAnswers[spec.id] = text
  }

  public func toggle(_ label: String, in spec: QuestionSpec) {
    var selected = selections[spec.id, default: []]
    if spec.multiSelect == true {
      selected.formSymmetricDifference([label])
    } else {
      selected = selected.contains(label) ? [] : [label]
    }
    selections[spec.id] = selected
    dropTypedAnswerIfOtherDeselected(spec)
  }

  public func pick(_ label: String, in spec: QuestionSpec) {
    toggle(label, in: spec)
    guard advancesAfterPicking(label, in: spec) else { return }
    let pickedPage = page
    Task { [weak self] in
      try? await Task.sleep(for: Self.autoAdvanceDelay)
      guard let self, self.page == pickedPage else { return }
      self.move(by: 1)
    }
  }

  public func advancesAfterPicking(_ label: String, in spec: QuestionSpec) -> Bool {
    spec.multiSelect != true && label != Self.otherToken && isSelected(label, in: spec) && !isLastPage
  }

  public func select(_ label: String, in spec: QuestionSpec) {
    selections[spec.id] = [label]
  }

  public func move(by delta: Int) {
    let next = page + delta
    guard request.questions.indices.contains(next) else { return }
    isPagingForward = delta > 0
    page = next
  }

  private var hasAnyAnswer: Bool {
    request.questions.contains { answer(for: $0) != nil }
  }

  private func dropTypedAnswerIfOtherDeselected(_ spec: QuestionSpec) {
    guard spec.allowsOther, !isOtherSelected(spec) else { return }
    typedAnswers[spec.id] = nil
  }

  private func answer(for spec: QuestionSpec) -> QuestionAnswerEntry? {
    let labels = spec.options.map(\.label).filter { isSelected($0, in: spec) }
    let typed = trimmedTypedAnswer(spec)
    if labels.isEmpty, typed.isEmpty { return nil }
    if isOtherSelected(spec) { return QuestionAnswerEntry(answers: labels + [typed]) }
    return QuestionAnswerEntry(answers: labels, note: typed.isEmpty ? nil : typed)
  }
}
