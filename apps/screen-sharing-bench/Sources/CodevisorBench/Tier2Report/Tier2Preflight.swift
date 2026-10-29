struct Tier2Preflight: Decodable {
  let machine: String
  let chip: String
  let os: String
  let load1: Double
  let thermal: String
  let ciJobs: Int
  let mainDisplay: String?
  let mainDisplayName: String?
  let displays: [String]
  let screenSharingPeers: [String]
  let problems: [String]
}
