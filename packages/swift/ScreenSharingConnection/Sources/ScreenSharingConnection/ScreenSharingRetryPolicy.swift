public enum ScreenSharingRetryPolicy {
  public static let waits: [Duration] = [.zero, .seconds(1), .seconds(2), .seconds(4), .seconds(8)]

  static func wait(afterTries used: Int) -> Duration? {
    waits.indices.contains(used) ? waits[used] : nil
  }
}
