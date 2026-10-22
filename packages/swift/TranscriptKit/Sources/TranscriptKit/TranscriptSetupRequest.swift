import ACPKit

public struct TranscriptSetupRequest: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Equatable {
    case computerUse
    case chromeExtension
    case chromeExtensionUpdate
  }

  public enum State: Sendable, Equatable {
    case pending
    case setUp
    case declined
  }

  public var id: String
  public var kind: Kind
  public var state: State

  public init(id: String, kind: Kind, state: State) {
    self.id = id
    self.kind = kind
    self.state = state
  }

  public static func kind(of questions: [QuestionSpec]) -> Kind? {
    questions.lazy.compactMap { kind(of: $0.presentation) }.first
  }

  public static func kind(of presentation: QuestionPresentation?) -> Kind? {
    switch presentation {
    case .computerUsePermissions: .computerUse
    case .browserExtensionSetup, .browserExtensionWaiting: .chromeExtension
    case .browserExtensionUpdate: .chromeExtensionUpdate
    case nil: nil
    }
  }
}
