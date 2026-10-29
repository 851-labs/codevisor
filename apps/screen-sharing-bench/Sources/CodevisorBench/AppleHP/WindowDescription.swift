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
    texts = Self.texts(in: window, depth: 6)
  }

  private static func texts(in element: AccessibilityElement, depth: Int) -> [String] {
    guard depth > 0 else { return [] }

    let role = element.string(kAXRoleAttribute) ?? "?"
    let labels = [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute].compactMap(element.string)
    let own = labels.filter { !$0.isEmpty }.map { "\(role): \($0)" }
    return own + element.children().flatMap { texts(in: $0, depth: depth - 1) }
  }
}
