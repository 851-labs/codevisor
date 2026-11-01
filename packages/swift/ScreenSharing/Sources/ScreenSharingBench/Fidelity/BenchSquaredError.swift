import Accelerate

public struct BenchSquaredError: Sendable, Equatable {
  public static let none = BenchSquaredError(sum: 0, count: 0)

  public var sum: Double
  public var count: Int

  public init(sum: Double, count: Int) {
    self.sum = sum
    self.count = count
  }

  public init(_ reference: [Float], _ shown: [Float]) {
    precondition(reference.count == shown.count, "Compared planes must be the same size")
    self.init(sum: Double(vDSP.distanceSquared(reference, shown)), count: reference.count)
  }

  public init(_ reference: [Float], _ shown: [Float], mask: [Bool]) {
    var sum = 0.0
    var count = 0
    for index in mask.indices where mask[index] {
      let difference = Double(reference[index] - shown[index])
      sum += difference * difference
      count += 1
    }
    self.init(sum: sum, count: count)
  }

  public var mean: Double {
    count > 0 ? sum / Double(count) : 0
  }

  public var psnr: Double? {
    count > 0 ? BenchSimilarity.psnr(meanSquaredError: mean) : nil
  }

  public static func + (lhs: BenchSquaredError, rhs: BenchSquaredError) -> BenchSquaredError {
    BenchSquaredError(sum: lhs.sum + rhs.sum, count: lhs.count + rhs.count)
  }
}
