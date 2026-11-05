struct VCPLevelsStage: Encodable {
  let stage: String
  let exact: Bool
  let maxError: Int
  let mismatches: [String]
  let tags: [String: String]?
  let error: String?

  init(_ stage: String, failed error: any Error) {
    self.stage = stage
    exact = false
    maxError = 0
    mismatches = []
    tags = nil
    self.error = "\(error)"
  }

  init(_ stage: String, values: [[Int]], expecting expectation: VCPLevelsExpectation, tags: [String: String]? = nil) {
    self.stage = stage
    let expected = VCPLevelsRamp.colours.map(expectation.values)
    let wrong = expected.indices.filter { values[$0] != expected[$0] }
    exact = wrong.isEmpty
    maxError = wrong.flatMap { index in zip(values[index], expected[index]).map { abs($0 - $1) } }.max() ?? 0
    mismatches = wrong.map { Self.text(expected[$0]) + "→" + Self.text(values[$0]) }
    self.tags = tags
    error = nil
  }

  private static func text(_ values: [Int]) -> String {
    values.map(String.init).joined(separator: ",")
  }
}

struct VCPLevelsVariant: Encodable {
  let input: String
  let accessUnits: Int
  let stream: [String: String]
  let stages: [VCPLevelsStage]
}

struct VCPLevelsReport: Encodable {
  let machine: String
  let captures: [VCPLevelsStage]
  let conversions: [VCPLevelsStage]
  let variants: [VCPLevelsVariant]
}
