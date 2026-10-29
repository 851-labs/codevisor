@MainActor
enum BenchLauncher {
  static func run(_ arguments: [String]) async -> BenchExitStatus {
    guard let name = arguments.first, let command = BenchCommands.named(name) else {
      BenchConsole.error(BenchUsage.overview)
      return .usage
    }

    do {
      let options = try BenchOptions(Array(arguments.dropFirst()))
      let instance = try command.init(options: options)
      try options.rejectUnread()
      try await instance.run()
      return .success
    } catch let error as BenchUsageError {
      BenchConsole.error("\(error.message)\nusage: CodevisorBench \(command.name) \(command.usage)")
      return .usage
    } catch {
      BenchConsole.error("\(command.name) failed: \(error)")
      return .failure
    }
  }
}
