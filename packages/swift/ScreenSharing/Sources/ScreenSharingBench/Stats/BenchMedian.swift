public enum BenchMedian {
  public static func of(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }

    let sorted = values.sorted()
    let middle = sorted.count / 2
    guard sorted.count.isMultiple(of: 2) else { return sorted[middle] }

    return (sorted[middle - 1] + sorted[middle]) / 2
  }
}
