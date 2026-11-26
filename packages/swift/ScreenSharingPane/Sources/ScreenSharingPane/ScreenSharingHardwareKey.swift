import ScreenSharing

struct ScreenSharingHardwareKey {
  static let characterUsages: Set<Int> = Set(4...39).union(45...56).union([100])
  static let chordModifiers: ScreenSharingModifiers = [.control, .option, .command]

  var usage: Int
  var characters = ""
  var unmodifiedCharacters = ""
  var modifiers: ScreenSharingModifiers = []

  func events(asCharacters: Bool) -> [ScreenSharingInputEvent]? {
    if asCharacters, let typed = typedCharacter() { return typed }
    guard let code = ScreenSharingKeyboard.code(forHIDUsage: usage) else { return nil }

    return ScreenSharingKeyboard.press(code: code, modifiers: modifiers)
  }

  private func typedCharacter() -> [ScreenSharingInputEvent]? {
    guard Self.characterUsages.contains(usage) else { return nil }

    let events = isChord ? chord() : plainCharacter()
    return events.isEmpty ? nil : events
  }

  private var isChord: Bool { !modifiers.isDisjoint(with: Self.chordModifiers) }

  private func chord() -> [ScreenSharingInputEvent] {
    guard unmodifiedCharacters.count == 1 else { return [] }

    return ScreenSharingKeyboard.type(unmodifiedCharacters, modifiers: modifiers)
  }

  private func plainCharacter() -> [ScreenSharingInputEvent] {
    guard characters.count == 1 else { return [] }

    return ScreenSharingKeyboard.type(characters, modifiers: modifiers.subtracting(.shift))
  }
}
