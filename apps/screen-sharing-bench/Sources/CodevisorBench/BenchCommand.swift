@MainActor
protocol BenchCommand {
  static var name: String { get }
  static var summary: String { get }
  static var usage: String { get }

  init(options: BenchOptions) throws
  func run() async throws
}
