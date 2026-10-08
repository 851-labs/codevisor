import Foundation

/// One option of an agent-asked question.
public struct QuestionOption: Sendable, Codable, Equatable, Identifiable {
  public var label: String
  public var description: String?

  public var id: String { label }

  public init(label: String, description: String? = nil) {
    self.label = label
    self.description = description
  }
}

/// Optional first-party composer treatment for deterministic setup flows.
public enum QuestionPresentation: String, Sendable, Codable, Equatable {
  case browserChoice
  case browserExtensionSetup
  case browserExtensionWaiting
}

/// One question inside a blocking question request.
public struct QuestionSpec: Sendable, Codable, Equatable, Identifiable {
  public var id: String
  public var header: String?
  public var question: String
  public var options: [QuestionOption]
  public var multiSelect: Bool?
  public var allowsOther: Bool
  public var isSecret: Bool?
  /// Answer label submitted by the composer's native back-arrow control.
  /// It is navigation and does not appear in the option list.
  public var backOptionLabel: String?
  /// Selects a dedicated first-party composer UI instead of generic options.
  public var presentation: QuestionPresentation?

  public init(
    id: String,
    header: String? = nil,
    question: String,
    options: [QuestionOption] = [],
    multiSelect: Bool? = nil,
    allowsOther: Bool = true,
    isSecret: Bool? = nil,
    backOptionLabel: String? = nil,
    presentation: QuestionPresentation? = nil
  ) {
    self.id = id
    self.header = header
    self.question = question
    self.options = options
    self.multiSelect = multiSelect
    self.allowsOther = allowsOther
    self.isSecret = isSecret
    self.backOptionLabel = backOptionLabel
    self.presentation = presentation
  }
}

/// A blocking agent question: the turn holds until the client answers via
/// the answer endpoint (or the provider auto-resolves it).
public struct QuestionRequest: Sendable, Codable, Equatable {
  public var questionId: String
  /// Context line shown above the questions (e.g. an MCP server's
  /// elicitation message).
  public var message: String?
  public var questions: [QuestionSpec]
  public var autoResolutionMs: Int?

  public init(
    questionId: String,
    message: String? = nil,
    questions: [QuestionSpec],
    autoResolutionMs: Int? = nil
  ) {
    self.questionId = questionId
    self.message = message
    self.questions = questions
    self.autoResolutionMs = autoResolutionMs
  }

  /// The stable question id + accept label the agent-runtime tags onto
  /// Claude's ExitPlanMode approval (see `claude.ts`). Kept in sync there so
  /// the client recognizes an accepted plan and can leave plan mode as it
  /// answers.
  public static let exitPlanModeId = "exit_plan_mode"
  public static let implementPlanLabel = "Implement plan"
  public static let keepPlanningLabel = "Keep planning"
}

public enum QuestionOutcome: String, Sendable, Codable, Equatable {
  case answered
  case cancelled
  case autoResolved
}

/// The user's reply to one question: chosen option labels (or the free-text
/// entry) plus an optional note typed alongside a selection.
public struct QuestionAnswerEntry: Sendable, Codable, Equatable {
  public var answers: [String]
  public var note: String?

  public init(answers: [String], note: String? = nil) {
    self.answers = answers
    self.note = note
  }
}

/// Terminal event for a question request; pairs with the `question` event by
/// `questionId` and carries everything needed to render the answered card.
public struct QuestionResolution: Sendable, Codable, Equatable {
  public var questionId: String
  public var outcome: QuestionOutcome
  public var questions: [QuestionSpec]
  public var answers: [String: QuestionAnswerEntry]?
  /// Durable transcript position the server assigned the resolution, so the
  /// answered-question row keeps its place in history instead of sorting
  /// after work that arrived later.
  public var statePosition: Int?

  public init(
    questionId: String,
    outcome: QuestionOutcome,
    questions: [QuestionSpec],
    answers: [String: QuestionAnswerEntry]? = nil,
    statePosition: Int? = nil
  ) {
    self.questionId = questionId
    self.outcome = outcome
    self.questions = questions
    self.answers = answers
    self.statePosition = statePosition
  }
}
