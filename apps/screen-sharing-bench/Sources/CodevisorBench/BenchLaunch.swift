@MainActor
enum BenchLaunch {
  case command(any BenchCommand)
  case finished(BenchExitStatus)

  var presentsWindows: Bool {
    guard case .command(let command) = self else { return false }

    return command.presentsWindows
  }
}
