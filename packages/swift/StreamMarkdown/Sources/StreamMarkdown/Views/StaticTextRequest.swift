#if canImport(AppKit)
  import AppKit

  public struct StaticTextKey: Hashable, Sendable {
    let identity: Int
    let layoutWidth: Int
    let scale: Int
    let appearance: String

    init(identity: Int, request: StaticTextLayout, scale: CGFloat, appearance: NSAppearance.Name) {
      self.identity = identity
      layoutWidth = request.widthKey
      self.scale = Int((scale * 100).rounded())
      self.appearance = appearance.rawValue
    }
  }

  public enum StaticTextLayout: Hashable, Sendable {
    case wrapping(width: CGFloat, inset: CGFloat)
    case natural(inset: CGFloat)

    var widthKey: Int {
      switch self {
      case let .wrapping(width, _): Int((width * 2).rounded())
      case .natural: 0
      }
    }

    var inset: CGFloat {
      switch self {
      case let .wrapping(_, inset), let .natural(inset): inset
      }
    }

    var containerWidth: CGFloat {
      switch self {
      case let .wrapping(width, inset): max(1, width - inset * 2)
      case .natural: 100_000
      }
    }

    var wrapsText: Bool {
      if case .wrapping = self { return true }
      return false
    }
  }

  public struct StaticTextRequest: Sendable {
    let key: StaticTextKey
    let layout: StaticTextLayout
    let scale: CGFloat
    let appearance: NSAppearance.Name
    let makeText: @Sendable () -> NSAttributedString

    init(
      identity: Int,
      layout: StaticTextLayout,
      scale: CGFloat,
      appearance: NSAppearance.Name,
      makeText: @escaping @Sendable () -> NSAttributedString
    ) {
      key = StaticTextKey(identity: identity, request: layout, scale: scale, appearance: appearance)
      self.layout = layout
      self.scale = scale
      self.appearance = appearance
      self.makeText = makeText
    }
  }
#endif
