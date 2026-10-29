struct BenchClockOffsetRead {
  let absoluteBefore: UInt64
  let continuous: UInt64
  let absoluteAfter: UInt64

  var spanTicks: UInt64 {
    absoluteAfter >= absoluteBefore ? absoluteAfter - absoluteBefore : .max
  }

  var continuousMinusAbsoluteTicks: UInt64 {
    let difference = Int64(bitPattern: continuous &- absoluteBefore)
    return UInt64(max(difference, 0))
  }
}
