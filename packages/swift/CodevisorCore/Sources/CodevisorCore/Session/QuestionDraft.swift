import ACPKit
import Foundation
import Observation

@MainActor
@Observable
public final class QuestionDraft {
  public static let otherToken = "__other__"

  public let request: QuestionRequest
  public private(set) var page = 0
  public private(set) var isPagingForward = true
  public private(set) var selections: [String: Set<String>] = [:]
  public private(set) var notes: [String: String] = [:]
  public private(set) var revealedNotes: Set<String> = []

  public init(request: QuestionRequest) {
    self.request = request
  }

  public var question: QuestionSpec? {
    request.questions.indices.contains(page) ? request.questions[page] : nil
  }

  public var pageCount: Int { request.questions.count }

  public var isLastPage: Bool { page >= pageCount - 1 }

  public var isSubmittable: Bool {
    hasAnyAnswer && request.questions.allSatisfy { !isOtherSelected($0) || !trimmedNote($0).isEmpty }
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

  public func showsNoteField(_ spec: QuestionSpec) -> Bool {
    isOtherSelected(spec) || revealedNotes.contains(spec.id) || !trimmedNote(spec).isEmpty
  }

  public func note(for spec: QuestionSpec) -> String {
    notes[spec.id] ?? ""
  }

  public func trimmedNote(_ spec: QuestionSpec) -> String {
    note(for: spec).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func setNote(_ text: String, for spec: QuestionSpec) {
    notes[spec.id] = text
  }

  public func revealNote(for spec: QuestionSpec) {
    revealedNotes.insert(spec.id)
  }

  public func toggle(_ label: String, in spec: QuestionSpec) {
    var selected = selections[spec.id, default: []]
    if spec.multiSelect == true {
      selected.formSymmetricDifference([label])
    } else {
      selected = selected.contains(label) ? [] : [label]
    }
    selections[spec.id] = selected
    dropOtherAnswerIfDeselected(spec)
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

  private func dropOtherAnswerIfDeselected(_ spec: QuestionSpec) {
    guard !isOtherSelected(spec), !revealedNotes.contains(spec.id) else { return }
    notes[spec.id] = nil
  }

  private func answer(for spec: QuestionSpec) -> QuestionAnswerEntry? {
    let labels = spec.options.map(\.label).filter { isSelected($0, in: spec) }
    let note = trimmedNote(spec)
    if labels.isEmpty, note.isEmpty { return nil }
    if labels.isEmpty, isOtherSelected(spec) { return QuestionAnswerEntry(answers: [note]) }
    return QuestionAnswerEntry(answers: labels, note: note.isEmpty ? nil : note)
  }
}
