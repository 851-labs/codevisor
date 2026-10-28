import Foundation

@MainActor
final class ProjectCloneLog {
  struct Line {
    let stream: String
    let text: String
  }

  private static let percentStep = 10.0
  private var lastMark: String?

  func line(for event: ProjectSetupEvent) -> Line? {
    switch event {
    case let .log(stream, line): Line(stream: stream, text: line)
    case let .progress(clone): progressLine(clone)
    default: nil
    }
  }

  private func progressLine(_ clone: ProjectCloneProgress) -> Line? {
    let mark = "\(clone.stage) \(Int((clone.percent ?? 0) / Self.percentStep))"
    guard mark != lastMark else { return nil }

    lastMark = mark
    return Line(stream: "stdout", text: Self.text(ProjectMachineSetup.progress(for: clone)))
  }

  private static func text(_ progress: ProjectMachineSetup.SetupProgress) -> String {
    let percent = progress.fraction.map { " \(Int($0 * 100))%" } ?? ""
    let detail = progress.detail.map { " (\($0))" } ?? ""
    return progress.label + percent + detail
  }
}
