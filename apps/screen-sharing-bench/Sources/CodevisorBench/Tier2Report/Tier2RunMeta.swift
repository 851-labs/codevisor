struct Tier2RunMeta: Decodable {
  enum System: String, Decodable {
    case appleHP = "apple-hp"
    case codevisor
    case floor
  }

  let index: Int
  let scene: String
  let resolution: String?
  let network: String?
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
}
