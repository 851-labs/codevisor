@MainActor
enum BenchCommands {
  static let all: [any BenchCommand.Type] = [
    PlayerCommand.self,
    GenerateCommand.self,
  ]

  static func named(_ name: String) -> (any BenchCommand.Type)? {
    all.first { $0.name == name }
  }
}
