extension TranscriptInlineCard {
  public struct Action {
    public enum Emphasis {
      case primary
      case quiet
    }

    let title: String
    let emphasis: Emphasis
    let perform: () -> Void

    public init(_ title: String, emphasis: Emphasis, perform: @escaping () -> Void) {
      self.title = title
      self.emphasis = emphasis
      self.perform = perform
    }
  }
}
