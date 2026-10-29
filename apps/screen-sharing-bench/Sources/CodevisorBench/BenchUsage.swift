@MainActor
enum BenchUsage {
  private static let columnGap = 2

  static var overview: String {
    let header = ["usage: CodevisorBench <command> [--option value …]", "", "commands:"]
    let width = (BenchCommands.all.map { $0.name.count }.max() ?? 0) + columnGap
    return (header + BenchCommands.all.map { line($0, nameWidth: width) }).joined(separator: "\n")
  }

  private static func line(_ command: any BenchCommand.Type, nameWidth: Int) -> String {
    "  \(command.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0))\(command.summary)"
  }
}
