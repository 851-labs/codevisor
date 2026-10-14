import Foundation
import Observation

@MainActor
@Observable
public final class ErrorReporter {
  public struct Entry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let message: String?

    public init(id: UUID = UUID(), title: String, message: String? = nil) {
      self.id = id
      self.title = title
      self.message = message
    }
  }

  public static let shared = ErrorReporter()

  public private(set) var entries: [Entry] = []

  public var autoDismissDelay: Duration = .seconds(10)
  public var maxVisible = 3

  private var dismissTasks: [UUID: Task<Void, Never>] = [:]

  public init() {}

  public func report(_ title: String, message: String? = nil) {
    Log.surfaced.error("\(title, privacy: .public)\(message.map { ": \($0)" } ?? "", privacy: .public)")
    if let existing = entries.last, existing.title == title, existing.message == message {
      scheduleDismissal(of: existing.id)
      return
    }
    let entry = Entry(title: title, message: message)
    entries.append(entry)
    while entries.count > maxVisible {
      dismiss(entries[0].id)
    }
    scheduleDismissal(of: entry.id)
  }

  public func report(
    _ issue: DiagnosticIssueName,
    title: String,
    message: String? = nil
  ) {
    DiagnosticsClient.shared.capture(issue)
    report(title, message: message)
  }

  public func report(_ title: String, error: any Error) {
    report(title, message: Self.userFacingMessage(for: error))
  }

  public func report(_ issue: DiagnosticIssueName, title: String, error: any Error) {
    DiagnosticsClient.shared.capture(issue)
    report(title, message: Self.userFacingMessage(for: error))
  }

  public func dismiss(_ id: UUID) {
    dismissTasks[id]?.cancel()
    dismissTasks[id] = nil
    entries.removeAll { $0.id == id }
  }

  public func dismissAll() {
    for entry in entries { dismissTasks[entry.id]?.cancel() }
    dismissTasks = [:]
    entries = []
  }

  private func scheduleDismissal(of id: UUID) {
    dismissTasks[id]?.cancel()
    let delay = autoDismissDelay
    dismissTasks[id] = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self?.dismiss(id)
    }
  }

  public static func userFacingMessage(for error: any Error) -> String {
    serverErrorMessage(error)
  }
}
