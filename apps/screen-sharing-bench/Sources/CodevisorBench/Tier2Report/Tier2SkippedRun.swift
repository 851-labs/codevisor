struct Tier2SkippedRun: Codable, Equatable {
  let name: String
  let reasons: [String]

  var text: String {
    "`\(name)` (\(reasons.joined(separator: "; ")))"
  }
}
