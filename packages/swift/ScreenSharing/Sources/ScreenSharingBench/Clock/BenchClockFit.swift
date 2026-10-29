struct BenchClockFit {
  let intercept: Double
  let slope: Double
  let maximumResidual: Double

  init(_ samples: [BenchClockSample], referenceNs: Int64) {
    let points = samples.map { (elapsed: Double($0.localNs - referenceNs), offset: $0.offsetNs) }
    let meanElapsed = points.map(\.elapsed).reduce(0, +) / Double(points.count)
    let meanOffset = points.map(\.offset).reduce(0, +) / Double(points.count)
    let spread = points.map { ($0.elapsed - meanElapsed) * ($0.elapsed - meanElapsed) }.reduce(0, +)
    let covariance = points.map { ($0.elapsed - meanElapsed) * ($0.offset - meanOffset) }.reduce(0, +)
    let slope = spread > 0 ? covariance / spread : 0
    let intercept = meanOffset - slope * meanElapsed
    self.slope = slope
    self.intercept = intercept
    maximumResidual = points.map { abs($0.offset - (intercept + slope * $0.elapsed)) }.max() ?? 0
  }
}
