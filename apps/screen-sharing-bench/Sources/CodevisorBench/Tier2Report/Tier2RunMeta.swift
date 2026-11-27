import ScreenSharingBench

struct Tier2RunMeta: Decodable {
  enum System: String, Decodable {
    case appleHP = "apple-hp"
    case codevisor
    case codevisorV2 = "codevisor-v2"
    case codevisorV2VCP = "codevisor-v2-vcp"
    case codevisorV2Before = "codevisor-v2-before"
    case codevisorV2VCPBefore = "codevisor-v2-vcp-before"
    case floor
  }

  static let engineV2 = "v2"
  static let inputScene = "input"

  let index: Int
  let scene: String
  let resolution: String?
  let network: String?
  let viewerDisplay: String?
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
    case .codevisorV2VCP: .codevisorV2VCP
    case .codevisorV2Before: .codevisorV2Before
    case .codevisorV2VCPBefore: .codevisorV2VCPBefore
    case .floor: nil
    }
  }

  var isCodevisor: Bool {
    system != .appleHP && system != .floor
  }

  var isInput: Bool {
    scene == Self.inputScene
  }

  var isLocalInputFloor: Bool {
    isInput && system == .floor
  }
}
