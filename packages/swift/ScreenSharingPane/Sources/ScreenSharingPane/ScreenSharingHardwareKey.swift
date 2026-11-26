import ScreenSharing

struct ScreenSharingHardwareKey {
  static let characterUsages: Set<Int> = Set(4...39).union(45...56).union([100])
  static let spaceUsage = 44
  static let chordModifiers: ScreenSharingModifiers = [.control, .option, .command]

  var usage: Int
  var characters = ""
  var unmodifiedCharacters = ""
  var modifiers: ScreenSharingModifiers = []

  func events(asCharacters: Bool, onScreen: ScreenSharingModifiers = []) -> [ScreenSharingInputEvent]? {
    if asCharacters, typesCharacters, let typed = typed(onScreen: onScreen) { return typed }
    guard let code = ScreenSharingKeyboard.code(forHIDUsage: usage) else { return nil }

    return ScreenSharingKeyboard.press(code: code, modifiers: modifiers.union(onScreen))
  }

  private var typesCharacters: Bool {
    Self.characterUsages.contains(usage) || spaceFinishedADeadKey
  }

  private var spaceFinishedADeadKey: Bool {
    guard usage == Self.spaceUsage, modifiers.isDisjoint(with: Self.chordModifiers) else { return false }

    return !characters.isEmpty && characters != " "
  }

  private func typed(onScreen: ScreenSharingModifiers) -> [ScreenSharingInputEvent]? {
    let held = modifiers.union(onScreen)
    let chord = held.intersection(Self.chordModifiers)
    if isDeadKey { return [] }
    guard isChord(chord) else { return Self.text(characters, shifted: onScreen.contains(.shift)) }

    return Self.chord(on: unmodifiedCharacters, holding: held)
  }

  private var isDeadKey: Bool {
    characters.isEmpty && modifiers.intersection(Self.chordModifiers).isSubset(of: .option)
  }

  private func isChord(_ chord: ScreenSharingModifiers) -> Bool {
    !chord.isEmpty && !(chord == .option && optionComposedACharacter)
  }

  private var optionComposedACharacter: Bool {
    guard modifiers.contains(.option), Self.isPrintable(characters) else { return false }

    return characters.lowercased() != unmodifiedCharacters.lowercased()
  }

  private static func text(_ text: String, shifted: Bool) -> [ScreenSharingInputEvent] {
    guard isPrintable(text) else { return [] }
    guard shifted else { return ScreenSharingKeyboard.type(text, modifiers: []) }
    guard let capitals = capitals(of: text) else {
      return ScreenSharingKeyboard.holding(.shift) { _ in [.text(text)] }
    }

    return ScreenSharingKeyboard.type(capitals, modifiers: [])
  }

  private static func capitals(of text: String) -> String? {
    let capitals = text.uppercased()
    return capitals != text && capitals.count == text.count ? capitals : nil
  }

  private static func chord(on text: String, holding modifiers: ScreenSharingModifiers) -> [ScreenSharingInputEvent]? {
    guard text.count == 1, let character = text.first, isPrintable(text) else { return nil }
    if let key = ScreenSharingKeyboard.key(for: character), !key.shifted {
      return ScreenSharingKeyboard.press(code: key.code, modifiers: modifiers)
    }

    let shifted = modifiers.contains(.shift) ? capitals(of: text) : nil
    return ScreenSharingKeyboard.holding(modifiers) { _ in [.text(shifted ?? text)] }
  }

  private static func isPrintable(_ text: String) -> Bool {
    !text.isEmpty && text.unicodeScalars.allSatisfy(isPrintable)
  }

  private static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .control, .format, .privateUse, .surrogate, .unassigned: false
    default: true
    }
  }
}
