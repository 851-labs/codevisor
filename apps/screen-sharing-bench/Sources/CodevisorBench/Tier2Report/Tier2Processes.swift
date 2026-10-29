enum Tier2Processes {
  static func host(_ system: Tier2RunMeta.System) -> Set<String> {
    switch system {
    case .appleHP: ["screensharingd", "ScreensharingAgent", "VTEncoderXPCService"]
    case .codevisor: ["CodevisorBench:share", "VTEncoderXPCService"]
    case .floor: []
    }
  }

  static func viewer(_ system: Tier2RunMeta.System) -> Set<String> {
    switch system {
    case .appleHP: ["Screen Sharing", "VTDecoderXPCService"]
    case .codevisor: ["CodevisorBench:view", "VTDecoderXPCService"]
    case .floor: ["CodevisorBench:view"]
    }
  }
}
