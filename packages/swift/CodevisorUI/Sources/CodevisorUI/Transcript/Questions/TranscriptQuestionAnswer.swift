import ACPKit
import Foundation

public struct TranscriptQuestionAnswer: Equatable, Sendable {
  private static let closingPunctuation: Set<Character> = [".", ",", ";", ":"]
  private static let leadingPunctuation = closingPunctuation.union(["—", "–", "-"])

  public let choices: [String]
  public let note: String?

  public init(_ spec: QuestionSpec, _ entry: QuestionAnswerEntry) {
    let parts = entry.answers.map { Self.part($0, options: spec.options) }
    choices = parts.compactMap(\.choice)
    note = Self.joined(parts.map(\.text) + [entry.note ?? ""])
  }

  public var isEmpty: Bool { choices.isEmpty && note == nil }

  public var text: String {
    let choice = choices.isEmpty ? nil : choices.joined(separator: ", ")
    return [choice, note].compactMap(\.self).joined(separator: "\n")
  }

  private struct Part {
    let choice: String?
    let text: String
  }

  private static func part(_ answer: String, options: [QuestionOption]) -> Part {
    guard let (label, rest) = leadingOption(of: answer, in: options) else { return Part(choice: nil, text: answer) }
    return Part(choice: label.title, text: String(rest.drop(while: isLeadingFiller)))
  }

  private static func leadingOption(
    of answer: String, in options: [QuestionOption]
  ) -> (QuestionOptionLabel, Substring)? {
    let candidates = options.flatMap { [$0.label, QuestionOptionLabel($0.label).title] }
    for candidate in candidates.sorted(by: { $0.count > $1.count }) {
      guard !candidate.isEmpty, answer.hasPrefix(candidate) else { continue }
      let rest = answer.dropFirst(candidate.count)
      if endsAtWordBoundary(rest) { return (QuestionOptionLabel(candidate), rest) }
    }
    return nil
  }

  private static func endsAtWordBoundary(_ rest: Substring) -> Bool {
    guard let first = rest.first else { return true }
    if first.isWhitespace { return true }
    guard closingPunctuation.contains(first) else { return false }
    return rest.dropFirst().first?.isWhitespace ?? true
  }

  private static func isLeadingFiller(_ character: Character) -> Bool {
    character.isWhitespace || leadingPunctuation.contains(character)
  }

  private static func joined(_ texts: [String]) -> String? {
    let kept = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    return kept.isEmpty ? nil : kept.joined(separator: "\n")
  }
}
