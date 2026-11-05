enum Tier2Processes {
  static func host(_ system: Tier2RunMeta.System) -> Set<String> {
    switch system {
    case .appleHP: ["screensharingd", "ScreensharingAgent", "avconferenced", "VTEncoderXPCService"]
    case .codevisorV2, .codevisorV2VCP: ["CodevisorBench:share", "VTEncoderXPCService"]
    case .floor: []
    }
  }

  static func viewer(_ system: Tier2RunMeta.System) -> Set<String> {
    switch system {
    case .appleHP: ["Screen Sharing", "avconferenced", "VTDecoderXPCService"]
    case .codevisorV2, .codevisorV2VCP: ["CodevisorBench:view", "VTDecoderXPCService"]
    case .floor: ["CodevisorBench:view"]
    }
  }
}
