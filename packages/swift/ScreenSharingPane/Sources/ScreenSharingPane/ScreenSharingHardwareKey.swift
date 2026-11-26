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
    if asCharacters, typesCharacters { return typed(onScreen: onScreen) }
    guard let code = ScreenSharingKeyboard.code(forHIDUsage: usage) else { return nil }

    return ScreenSharingKeyboard.press(code: code, modifiers: modifiers.union(onScreen))
  }

  private var typesCharacters: Bool {
    Self.characterUsages.contains(usage) || spaceFinishedADeadKey
  }

  private var spaceFinishedADeadKey: Bool {
    usage == Self.spaceUsage && !characters.isEmpty && characters != " "
  }

  private func typed(onScreen: ScreenSharingModifiers) -> [ScreenSharingInputEvent] {
    let held = modifiers.union(onScreen)
    guard isChord(held) else { return Self.text(characters, shifted: onScreen.contains(.shift)) }

    return Self.chord(on: unmodifiedCharacters, holding: held)
  }

  private func isChord(_ held: ScreenSharingModifiers) -> Bool {
    let chord = held.intersection(Self.chordModifiers)
    return !chord.isEmpty && !(chord == .option && optionComposedACharacter)
  }

  private var optionComposedACharacter: Bool {
    guard modifiers.contains(.option), Self.isPrintable(characters) else { return false }

    return characters.lowercased() != unmodifiedCharacters.lowercased()
  }

  private static func text(_ text: String, shifted: Bool) -> [ScreenSharingInputEvent] {
    guard isPrintable(text) else { return [] }
    guard shifted else { return ScreenSharingKeyboard.type(text, modifiers: []) }
    guard isOneKey(text) else { return ScreenSharingKeyboard.type(text.uppercased(), modifiers: []) }

    return ScreenSharingKeyboard.type(text, modifiers: .shift)
  }

  private static func chord(on text: String, holding modifiers: ScreenSharingModifiers) -> [ScreenSharingInputEvent] {
    guard text.count == 1, isPrintable(text) else { return [] }
    guard !isOneKey(text) else { return ScreenSharingKeyboard.type(text, modifiers: modifiers) }

    let letter = modifiers.contains(.shift) ? text.uppercased() : text
    return ScreenSharingKeyboard.holding(modifiers.subtracting(.shift)) { _ in [.text(letter)] }
  }

  private static func isOneKey(_ text: String) -> Bool {
    guard text.count == 1, let character = text.first else { return false }

    return ScreenSharingKeyboard.key(for: character) != nil
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
