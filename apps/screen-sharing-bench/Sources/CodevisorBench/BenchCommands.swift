@MainActor
enum BenchCommands {
  static let all: [any BenchCommand.Type] = [
    PlayerCommand.self,
    GenerateCommand.self,
    ObserveCommand.self,
    CalibrateCommand.self,
    SampleCommand.self,
    LoopbackCommand.self,
    PreflightCommand.self,
    ShareCommand.self,
    ViewCommand.self,
    AppleHPCommand.self,
    Tier2ReportCommand.self,
    RendezvousCommand.self,
    RecordCommand.self,
    SummarizeCommand.self,
    GateCommand.self,
    EncodeLabCommand.self,
    MediaTransportCommand.self,
  ]

  static func named(_ name: String) -> (any BenchCommand.Type)? {
    all.first { $0.name == name }
  }
}
