import ScreenSharingBench

struct Tier2RunMeta: Decodable {
  enum System: String, Decodable {
    case appleHP = "apple-hp"
    case codevisor
    case codevisorV2 = "codevisor-v2"
    case floor
  }

  static let engineV2 = "v2"

  let index: Int
  let scene: String
  let resolution: String?
  let network: String?
  let engine: String?
  let system: System
  let repetition: Int
  let seed: UInt64
  let durationS: Int
  let hostObserver: Bool
  let gitSha: String
  let startedAt: String
  let githubRunId: String?

  var resolutionLabel: String {
    resolution ?? Tier2Result.defaultResolution
  }

  var networkLabel: String {
    network ?? Tier2Result.defaultNetwork
  }

  var benchSystem: BenchSystem? {
    switch system {
    case .appleHP: .appleHP
    case .codevisor: engine == Self.engineV2 ? .codevisorV2 : .codevisor
    case .codevisorV2: .codevisorV2
    case .floor: nil
    }
  }

  var isCodevisor: Bool {
    system == .codevisor || system == .codevisorV2
  }
}
