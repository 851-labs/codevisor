import ApplicationServices

struct WindowDescription: Encodable, Sendable {
  let title: String?
  let subrole: String?
  let frame: String?
  let fullScreen: Bool?
  let texts: [String]

  init(_ window: AccessibilityElement) {
    title = window.string(kAXTitleAttribute)
    subrole = window.string(kAXSubroleAttribute)
    frame = window.frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" }
    fullScreen = window.bool("AXFullScreen")
    texts = Self.texts(in: window, depth: 4)
  }

  private static func texts(in element: AccessibilityElement, depth: Int) -> [String] {
    guard depth > 0 else { return [] }

    let own = [element.string(kAXValueAttribute), element.string(kAXDescriptionAttribute)].compactMap { $0 }
    return own.filter { !$0.isEmpty } + element.children().flatMap { texts(in: $0, depth: depth - 1) }
  }
}
