struct BenchGateRule {
  enum Threshold {
    case rise(fraction: Double, atLeast: Double)
    case fall(fraction: Double)
    case riseBy(Double)
    case fallBy(Double)
  }

  static let all = [
    BenchGateRule(metric: "e2e_p50_ms", threshold: .rise(fraction: 0.15, atLeast: 3)) { $0.e2eP50Ms },
    BenchGateRule(metric: "e2e_p95_ms", threshold: .rise(fraction: 0.20, atLeast: 5)) { $0.e2eP95Ms },
    BenchGateRule(metric: "updates_per_s", threshold: .fall(fraction: 0.05)) { $0.updatesPerS },
    BenchGateRule(metric: "freeze_ratio", threshold: .riseBy(0.02)) { $0.freezeRatio },
    BenchGateRule(metric: "psnr_y", threshold: .fallBy(0.5)) { $0.psnrY },
  ]

  let metric: String
  let threshold: Threshold
  let value: @Sendable (BenchGateSample) -> Double?

  func regressed(_ observed: Double, from baseline: Double) -> Bool {
    switch threshold {
    case .rise(let fraction, let atLeast): observed - baseline > max(fraction * baseline, atLeast)
    case .fall(let fraction): baseline - observed > fraction * baseline
    case .riseBy(let amount): observed - baseline > amount
    case .fallBy(let amount): baseline - observed > amount
    }
  }
}
