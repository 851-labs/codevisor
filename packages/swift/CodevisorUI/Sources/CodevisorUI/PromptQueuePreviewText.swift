public enum PromptQueuePreviewText {
  public static func singleLine(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
