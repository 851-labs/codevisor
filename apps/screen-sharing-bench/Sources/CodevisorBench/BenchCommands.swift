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
    Tier2DispatchesCommand.self,
    RendezvousCommand.self,
    RecordCommand.self,
    SummarizeCommand.self,
    GateCommand.self,
    EncodeLabCommand.self,
    MediaTransportCommand.self,
    InjectCommand.self,
    HostLabCommand.self,
    HostRunCommand.self,
    EncoderReleaseCommand.self,
    VCPLevelsCommand.self,
  ]

  static func named(_ name: String) -> (any BenchCommand.Type)? {
    all.first { $0.name == name }
  }
}
