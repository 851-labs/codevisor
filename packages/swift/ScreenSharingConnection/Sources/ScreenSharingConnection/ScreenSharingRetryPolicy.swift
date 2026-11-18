public enum ScreenSharingRetryPolicy {
  public static let waits: [Duration] = [.zero, .seconds(1), .seconds(2), .seconds(4), .seconds(8)]
  public static let quietWaits: [Duration] = [.seconds(15), .seconds(30), .seconds(60), .seconds(120), .seconds(300)]

  static func wait(afterTries used: Int) -> Duration? {
    waits.indices.contains(used) ? waits[used] : nil
  }

  static func quietWait(afterTries used: Int) -> Duration {
    quietWaits[min(used, quietWaits.count - 1)]
  }
}
