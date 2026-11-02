public enum BenchSystem: String, Codable, Sendable, CaseIterable {
  case appleHP = "apple-hp"
  case codevisor
  case codevisorV2 = "codevisor-v2"

  public static let codevisorSystems: [BenchSystem] = [.codevisor, .codevisorV2]
}
