import CodevisorCore
import Foundation
import Observation
import TranscriptKit

@MainActor
@Observable
public final class PluginAppSubjectLookup {
  public enum State: Equatable {
    case idle
    case checking
    case found(PluginModerationSubject)
    case missing
    case failed(String)
  }

  public private(set) var state: State = .idle
  @ObservationIgnored private var task: Task<Void, Never>?

  public var subject: PluginModerationSubject? {
    guard case let .found(subject) = state else { return nil }
    return subject
  }

  func resolve(_ app: CodevisorExecutionApp, connection: any PluginAppConnecting) {
    guard state == .idle else { return }

    retry(app, connection: connection)
  }

  func retry(_ app: CodevisorExecutionApp, connection: any PluginAppConnecting) {
    task?.cancel()
    state = .checking
    task = Task { [weak self] in
      let state = await Self.lookUp(app, connection: connection)
      guard !Task.isCancelled else { return }
      self?.state = state
    }
  }

  private static func lookUp(_ app: CodevisorExecutionApp, connection: any PluginAppConnecting) async -> State {
    do {
      guard let subject = try await connection.subject(for: app) else { return .missing }
      return .found(subject)
    } catch {
      return .failed(ErrorReporter.userFacingMessage(for: error))
    }
  }
}
