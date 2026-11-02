public enum ProgressStepSequence {
  public static func states(
    count: Int,
    current: Int,
    isFailed: Bool = false,
    skipped: Set<Int> = []
  ) -> [ProgressStepState] {
    (0..<count).map { index in
      state(at: index, current: current, isFailed: isFailed, skipped: skipped)
    }
  }

  private static func state(at index: Int, current: Int, isFailed: Bool, skipped: Set<Int>) -> ProgressStepState {
    if index > current { return .pending }
    if index == current { return isFailed ? .failed : .running }
    return skipped.contains(index) ? .skipped : .done
  }
}
