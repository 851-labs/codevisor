struct EncodeLabReport: Codable, Sendable {
  let resolution: String
  let results: [EncodeLabResult]
}
