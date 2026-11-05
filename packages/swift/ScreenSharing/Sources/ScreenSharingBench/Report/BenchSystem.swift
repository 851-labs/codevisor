public enum BenchSystem: String, Codable, Sendable, CaseIterable {
  case appleHP = "apple-hp"
  case codevisor
  case codevisorV2 = "codevisor-v2"
  case codevisorV2VCP = "codevisor-v2-vcp"

  public static let codevisorSystems: [BenchSystem] = [.codevisorV2, .codevisorV2VCP]

  public var isEngineV2: Bool { Self.codevisorSystems.contains(self) }
}
