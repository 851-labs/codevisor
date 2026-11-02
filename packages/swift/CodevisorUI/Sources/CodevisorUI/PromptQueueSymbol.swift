public enum PromptQueueSymbol {
  public static let queued = "text.line.first.and.arrowtriangle.forward"
  public static let steered = "text.insert"

  public static func name(steered: Bool) -> String {
    steered ? Self.steered : queued
  }
}
