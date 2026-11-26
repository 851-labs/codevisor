enum Tier2Processes {
  static func host(_ system: Tier2RunMeta.System) -> Set<String> {
    switch system {
    case .appleHP: ["screensharingd", "ScreensharingAgent", "avconferenced", "VTEncoderXPCService"]
    case .codevisor, .codevisorV2, .codevisorV2VCP, .codevisorV2Cap, .codevisorV2VCPCap:
      ["CodevisorBench:share", "VTEncoderXPCService"]
    case .floor: []
    }
  }

  static func viewer(_ system: Tier2RunMeta.System) -> Set<String> {
    switch system {
    case .appleHP: ["Screen Sharing", "avconferenced", "VTDecoderXPCService"]
    case .codevisor, .codevisorV2, .codevisorV2VCP, .codevisorV2Cap, .codevisorV2VCPCap:
      ["CodevisorBench:view", "VTDecoderXPCService"]
    case .floor: ["CodevisorBench:view"]
    }
  }
}
