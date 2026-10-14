import Foundation

public struct QuestionOption: Sendable, Codable, Equatable, Identifiable {
  public var label: String
  public var description: String?

  public var id: String { label }

  public init(label: String, description: String? = nil) {
    self.label = label
    self.description = description
  }
}

public enum QuestionPresentation: String, Sendable, Codable, Equatable {
  case browserChoice
  case browserExtensionSetup
  case browserExtensionWaiting
}

public struct QuestionSpec: Sendable, Codable, Equatable, Identifiable {
  public var id: String
  public var header: String?
  public var question: String
  public var options: [QuestionOption]
  public var multiSelect: Bool?
  public var allowsOther: Bool
  public var isSecret: Bool?
  public var backOptionLabel: String?
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

public struct QuestionRequest: Sendable, Codable, Equatable {
  public var questionId: String
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

  public static let exitPlanModeId = "exit_plan_mode"
  public static let implementPlanLabel = "Implement plan"
  public static let keepPlanningLabel = "Keep planning"
}

public enum QuestionOutcome: String, Sendable, Codable, Equatable {
  case answered
  case cancelled
  case autoResolved
}

public struct QuestionAnswerEntry: Sendable, Codable, Equatable {
  public var answers: [String]
  public var note: String?

  public init(answers: [String], note: String? = nil) {
    self.answers = answers
    self.note = note
  }
}

public struct QuestionResolution: Sendable, Codable, Equatable {
  public var questionId: String
  public var outcome: QuestionOutcome
  public var questions: [QuestionSpec]
  public var answers: [String: QuestionAnswerEntry]?
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
