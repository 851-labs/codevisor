public enum ProgressStepDetailText {
  public static func percent(_ fraction: Double) -> [String] {
    ["\(Int((fraction * 100).rounded()))%"]
  }

  public static func count(name: String, completed: Int, total: Int) -> [String] {
    guard total > 0 else { return name.isEmpty ? [] : [name] }

    let count = "\(completed) of \(total)"
    return name.isEmpty ? [count] : ["\(name) · \(count)", count]
  }
}
