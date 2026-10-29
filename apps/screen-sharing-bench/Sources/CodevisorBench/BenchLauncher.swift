import Foundation

@MainActor
enum BenchLauncher {
  static func prepare(_ arguments: [String]) -> BenchLaunch {
    guard let name = arguments.first, let command = BenchCommands.named(name) else {
      BenchConsole.error(BenchUsage.overview)
      return .finished(.usage)
    }

    do {
      let options = try BenchOptions(Array(arguments.dropFirst()))
      let instance = try command.init(options: options)
      try options.rejectUnread()
      return .command(instance)
    } catch {
      return .finished(failed(command.name, usage: command.usage, error))
    }
  }

  static func run(_ launch: BenchLaunch) async -> BenchExitStatus {
    switch launch {
    case .finished(let status):
      return status
    case .command(let command):
      let activity = ProcessInfo.processInfo.beginActivity(options: measuring, reason: "CodevisorBench is measuring")
      defer { ProcessInfo.processInfo.endActivity(activity) }

      do {
        try await command.run()
        return .success
      } catch {
        let type = type(of: command)
        return failed(type.name, usage: type.usage, error)
      }
    }
  }

  private static let measuring: ProcessInfo.ActivityOptions = [.userInitiated, .latencyCritical]

  private static func failed(_ name: String, usage: String, _ error: any Error) -> BenchExitStatus {
    if let error = error as? BenchUsageError {
      BenchConsole.error("\(error.message)\nusage: CodevisorBench \(name) \(usage)")
      return .usage
    }

    BenchConsole.error("\(name) failed: \(error)")
    return .failure
  }
}
