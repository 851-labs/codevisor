import ACPKit
import Foundation
import TranscriptKit

public struct ServerTranscriptInteraction: Decodable, Equatable, Sendable {
  public struct QuestionPayload: Decodable, Equatable, Sendable {
    public var message: String?
    public var questions: [QuestionSpec]
  }

  public struct QuestionAnswer: Decodable, Equatable, Sendable {
    public var outcome: QuestionOutcome
    public var answers: [String: QuestionAnswerEntry]?
  }

  public var id: String
  public var kind: String
  public var payload: QuestionPayload
  public var answer: QuestionAnswer?

  var transcriptInteraction: TranscriptInteraction? {
    guard kind == "question" else { return nil }
    if let setup = payload.questions.lazy.compactMap(\.pluginSetup).first { return finishedSetupCard(for: setup) }

    let request = QuestionRequest(questionId: id, message: payload.message, questions: payload.questions)
    let answer = answer.map { TranscriptQuestion.Answer(outcome: $0.outcome, entries: $0.answers ?? [:]) }
    return TranscriptInteraction(id: id, content: .question(TranscriptQuestion(request: request, answer: answer)))
  }

  private func finishedSetupCard(for request: JSONValue) -> TranscriptInteraction? {
    guard answer?.outcome == .autoResolved else { return nil }
    return TranscriptInteraction(
      id: id, content: .pluginSetup(TranscriptPluginSetup(id: id, state: .connected, request: request)))
  }
}
