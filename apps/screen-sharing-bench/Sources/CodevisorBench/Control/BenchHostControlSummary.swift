struct BenchHostControlSummary: Encodable {
  let requests: Int
  let grants: Int
  let denials: [String]
  let revocations: [String]
  let injectedEvents: Int
  let injected: [BenchInputStamp]
}
