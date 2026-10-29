import Darwin

public enum BenchMachClock {
  private static let offsetReads = 8

  public static func nowNs() -> Int64 {
    Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW))
  }

  public static func continuousMinusAbsoluteNs() -> Int64 {
    var tightest = readOffset()
    for _ in 1..<offsetReads where tightest.spanTicks > 0 {
      let read = readOffset()
      if read.spanTicks < tightest.spanTicks { tightest = read }
    }
    return nanoseconds(fromTicks: tightest.continuousMinusAbsoluteTicks)
  }

  public static func nanoseconds(fromTicks ticks: UInt64) -> Int64 {
    let scaled = ticks.multipliedFullWidth(by: UInt64(timebase.numer))
    return Int64(clamping: UInt64(timebase.denom).dividingFullWidth(scaled).quotient)
  }

  private static func readOffset() -> BenchClockOffsetRead {
    let before = mach_absolute_time()
    let continuous = mach_continuous_time()
    return BenchClockOffsetRead(absoluteBefore: before, continuous: continuous, absoluteAfter: mach_absolute_time())
  }

  private static let timebase: mach_timebase_info_data_t = {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return timebase
  }()
}
