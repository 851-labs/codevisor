public struct BenchCellSummary: Codable, Sendable, Equatable {
  public var cell: BenchCell
  public var repetitions: Int
  public var valid: Int
  public var errors: Int
  public var e2eP50Ms: Double?
  public var e2eP95Ms: Double?
  public var e2eP50MinMs: Double?
  public var e2eP50MaxMs: Double?
  public var updatesPerS: Double?
  public var freezeRatio: Double?
  public var psnrY: Double?
  public var bitrateMbps: Double?
  public var stagesP50Ms: BenchStageMedians

  public init(cell: BenchCell, repetitions: [BenchResult]) {
    let measured = repetitions.filter { $0.valid && $0.e2eMs != nil }
    let p50s = measured.compactMap(\.e2eMs?.p50)
    self.cell = cell
    self.repetitions = repetitions.count
    valid = measured.count
    errors = repetitions.reduce(0) { $0 + ($1.codecErrors ?? 0) } + repetitions.count { !$0.valid }
    e2eP50Ms = BenchMedian.of(p50s)
    e2eP95Ms = BenchMedian.of(measured.compactMap(\.e2eMs?.p95))
    e2eP50MinMs = p50s.min()
    e2eP50MaxMs = p50s.max()
    updatesPerS = BenchMedian.of(measured.map(\.updatesPerS))
    freezeRatio = BenchMedian.of(measured.compactMap(\.freezes?.ratio))
    psnrY = BenchMedian.of(measured.compactMap(\.text?.psnrY))
    bitrateMbps = BenchMedian.of(measured.compactMap(\.bitrateMbps?.p50))
    stagesP50Ms = BenchStageMedians(measured.compactMap(\.stagesMs))
  }

  public static func summaries(_ results: [BenchResult]) -> [BenchCellSummary] {
    var order: [BenchCell] = []
    var repetitions: [BenchCell: [BenchResult]] = [:]
    for result in results {
      let cell = BenchCell(result)
      if repetitions[cell] == nil { order.append(cell) }
      repetitions[cell, default: []].append(result)
    }
    return order.map { BenchCellSummary(cell: $0, repetitions: repetitions[$0] ?? []) }
  }
}
