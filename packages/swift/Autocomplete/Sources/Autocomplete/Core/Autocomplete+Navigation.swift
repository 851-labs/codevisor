public extension Autocomplete {
  struct Navigation: Sendable, Hashable {
    public var loop: Bool
    public var autoHighlight: Bool

    public init(loop: Bool, autoHighlight: Bool) {
      self.loop = loop
      self.autoHighlight = autoHighlight
    }

    public static let menu = Navigation(loop: false, autoHighlight: false)

    public static let inline = Navigation(loop: true, autoHighlight: true)
  }
}
