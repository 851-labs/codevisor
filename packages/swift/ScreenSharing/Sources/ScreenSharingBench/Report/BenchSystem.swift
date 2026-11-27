public enum BenchSystem: String, Codable, Sendable, CaseIterable {
  case appleHP = "apple-hp"
  case codevisor
  case codevisorV2 = "codevisor-v2"
  case codevisorV2VCP = "codevisor-v2-vcp"
  case codevisorV2Before = "codevisor-v2-before"
  case codevisorV2VCPBefore = "codevisor-v2-vcp-before"

  public static let engineV2Systems: [BenchSystem] = [
    .codevisorV2, .codevisorV2VCP, .codevisorV2Before, .codevisorV2VCPBefore,
  ]
}
