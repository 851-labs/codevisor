public enum BenchSystem: String, Codable, Sendable, CaseIterable {
  case appleHP = "apple-hp"
  case codevisor
  case codevisorV2 = "codevisor-v2"
  case codevisorV2VCP = "codevisor-v2-vcp"
  case codevisorV2Cap = "codevisor-v2-cap"
  case codevisorV2VCPCap = "codevisor-v2-vcp-cap"
  case codevisorV2VCPCapView = "codevisor-v2-vcp-cap-view"

  public static let engineV2Systems: [BenchSystem] = [
    .codevisorV2, .codevisorV2VCP, .codevisorV2Cap, .codevisorV2VCPCap, .codevisorV2VCPCapView,
  ]
}
