public extension Autocomplete {
  /// How keyboard navigation behaves at the list edges and before the user
  /// presses a key.
  struct Navigation: Sendable, Hashable {
    /// Whether arrows wrap from the last item to the first and back.
    public var loop: Bool
    /// Whether the first item is highlighted as soon as the list appears or
    /// the filter changes, so Return accepts it without an arrow press.
    public var autoHighlight: Bool

    public init(loop: Bool, autoHighlight: Bool) {
      self.loop = loop
      self.autoHighlight = autoHighlight
    }

    /// Xcode-style searchable menu: starts unhighlighted; entering a search
    /// highlights the first result. Arrows stop at the ends.
    public static let menu = Navigation(loop: false, autoHighlight: false)

    /// Inline popup under a text field: the first match is always ready to
    /// accept, arrows wrap.
    public static let inline = Navigation(loop: true, autoHighlight: true)
  }
}
