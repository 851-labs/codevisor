public enum BenchFrameGaps {
  public static func intervalsMs(between onGlassNs: [Int64]) -> [Double] {
    zip(onGlassNs, onGlassNs.dropFirst()).map { earlier, later in Double(later - earlier) / 1_000_000 }
  }
}
