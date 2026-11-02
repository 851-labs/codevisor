public enum BotMascotCategory: String, CaseIterable, Identifiable, Sendable {
  case color
  case headwear
  case eyewear

  public var id: Self { self }

  public var title: String {
    switch self {
    case .color: "Color"
    case .headwear: "Headwear"
    case .eyewear: "Eyewear"
    }
  }

  public var systemImage: String {
    switch self {
    case .color: "paintpalette"
    case .headwear: "crown"
    case .eyewear: "eyeglasses"
    }
  }
}
