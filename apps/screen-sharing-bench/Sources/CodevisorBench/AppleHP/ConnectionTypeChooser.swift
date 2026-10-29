import ApplicationServices

struct ConnectionTypeChooser {
  static let highPerformance = "High Performance"
  private static let proceed = "Continue"
  private static let searchDepth = 8
  private static let selectedAttribute = "AXSelected"
  private static let settle = Duration.milliseconds(300)
  private static let choosableRoles: Set<String> = [
    kAXRadioButtonRole, kAXRowRole, kAXCellRole, kAXButtonRole, kAXCheckBoxRole, "AXGroup",
  ]

  let window: AccessibilityElement

  static func find(in windows: [AccessibilityElement]) -> ConnectionTypeChooser? {
    windows.map(ConnectionTypeChooser.init).first { $0.option != nil && $0.continueButton != nil }
  }

  @MainActor
  func chooseHighPerformance() async -> Bool {
    guard let option, let continueButton else { return false }

    option.press()
    option.set(Self.selectedAttribute, to: true)
    try? await Task.sleep(for: Self.settle)
    guard Self.isSelected(option) else { return false }

    continueButton.press()
    return true
  }

  private var option: AccessibilityElement? {
    Self.first(in: window, depth: Self.searchDepth) {
      Self.choosableRoles.contains($0.string(kAXRoleAttribute) ?? "")
        && Self.label($0).hasPrefix(Self.highPerformance)
    }
  }

  private var continueButton: AccessibilityElement? {
    Self.first(in: window, depth: Self.searchDepth) {
      $0.string(kAXRoleAttribute) == kAXButtonRole && Self.label($0) == Self.proceed
    }
  }

  private static func isSelected(_ option: AccessibilityElement) -> Bool {
    option.bool(selectedAttribute) == true || option.bool(kAXValueAttribute) == true
  }

  private static func label(_ element: AccessibilityElement) -> String {
    let own = [element.string(kAXTitleAttribute), element.string(kAXDescriptionAttribute)]
      .compactMap { $0 }.first { !$0.isEmpty }
    return own ?? element.children().map(label).first { !$0.isEmpty } ?? element.string(kAXValueAttribute) ?? ""
  }

  private static func first(
    in element: AccessibilityElement, depth: Int, where matches: (AccessibilityElement) -> Bool
  ) -> AccessibilityElement? {
    guard depth > 0 else { return nil }
    if matches(element) { return element }

    for child in element.children() {
      if let found = first(in: child, depth: depth - 1, where: matches) { return found }
    }
    return nil
  }
}
