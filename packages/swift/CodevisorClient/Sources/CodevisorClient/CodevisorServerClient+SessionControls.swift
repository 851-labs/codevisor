import ACPKit
import Foundation

private struct CancelBody: Encodable {
  var clientActionId = UUID().uuidString
}

private struct SetModeBody: Encodable {
  var modeId: String
  var clientActionId = UUID().uuidString
}

private struct SetConfigBody: Encodable {
  var configId: String
  var value: String
  var clientActionId = UUID().uuidString
}

private struct SetConfigResponse: Decodable {
  var configId: String
  var configOptions: [SessionConfigOption]?
}

struct SetGoalBody: Encodable {
  var objective: String?
  var status: GoalStatus?
  var tokenBudget: TokenBudgetUpdate
  var clientActionId = UUID().uuidString

  private enum Keys: String, CodingKey {
    case objective, status, tokenBudget, clientActionId
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Keys.self)
    try container.encodeIfPresent(objective, forKey: .objective)
    try container.encodeIfPresent(status, forKey: .status)
    switch tokenBudget {
    case .keep:
      break
    case .clear:
      try container.encodeNil(forKey: .tokenBudget)
    case let .set(budget):
      try container.encode(budget, forKey: .tokenBudget)
    }
    try container.encode(clientActionId, forKey: .clientActionId)
  }
}

private struct AnswerQuestionBody: Encodable {
  var outcome: String
  var answers: [String: QuestionAnswerEntry]?
  var clientActionId = UUID().uuidString
}

extension CodevisorServerClient {
  public func cancelSession(id: UUID) async throws {
    try await sendNoResponse(
      "/v1/sessions/\(id.uuidString)/cancel",
      method: "POST",
      body: CancelBody()
    )
  }

  public func setSessionMode(id: UUID, modeId: String) async throws {
    try await sendNoResponse(
      "/v1/sessions/\(id.uuidString)/mode",
      method: "POST",
      body: SetModeBody(modeId: modeId)
    )
  }

  public func setSessionConfig(id: UUID, configId: String, value: String) async throws {
    _ = try await setSessionConfigAndReturnOptions(id: id, configId: configId, value: value)
  }

  public func setSessionConfigAndReturnOptions(
    id: UUID,
    configId: String,
    value: String
  ) async throws -> [SessionConfigOption]? {
    let response: SetConfigResponse = try await send(
      "/v1/sessions/\(id.uuidString)/config",
      method: "POST",
      body: SetConfigBody(configId: configId, value: value),
      timeout: Self.configRequestTimeout
    )
    return response.configOptions
  }

  static let configRequestTimeout: TimeInterval = 20

  @discardableResult
  public func setSessionGoal(
    id: UUID,
    objective: String?,
    status: GoalStatus?,
    tokenBudget: TokenBudgetUpdate
  ) async throws -> SessionGoal {
    try await send(
      "/v1/sessions/\(id.uuidString)/goal",
      method: "POST",
      body: SetGoalBody(objective: objective, status: status, tokenBudget: tokenBudget)
    )
  }

  public func clearSessionGoal(id: UUID) async throws {
    try await sendNoResponse("/v1/sessions/\(id.uuidString)/goal", method: "DELETE")
  }

  public func cancelSessionAutoResume(id: UUID) async throws {
    try await sendNoResponse("/v1/sessions/\(id.uuidString)/auto-resume", method: "DELETE")
  }

  public func answerSessionQuestion(
    id: UUID,
    questionId: String,
    outcome: String,
    answers: [String: QuestionAnswerEntry]?
  ) async throws {
    try await sendNoResponse(
      "/v1/sessions/\(id.uuidString)/questions/\(questionId)/answer",
      method: "POST",
      body: AnswerQuestionBody(outcome: outcome, answers: answers)
    )
  }
}
