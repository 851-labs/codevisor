public enum BenchSystem: String, Codable, Sendable, CaseIterable {
  case appleHP = "apple-hp"
  case codevisor
  case codevisorV2 = "codevisor-v2"
  case codevisorV2VCP = "codevisor-v2-vcp"

  public static let engineV2Systems: [BenchSystem] = [.codevisorV2, .codevisorV2VCP]
}
