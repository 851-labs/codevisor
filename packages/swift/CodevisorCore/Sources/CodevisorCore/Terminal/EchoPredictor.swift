import Foundation

public struct EchoPredictor: Sendable {
  public static let enableAbove: Duration = .milliseconds(30)
  public static let disableBelow: Duration = .milliseconds(20)
  public static let underlineAfter: Duration = .milliseconds(80)
  public static let glitchAfter: Duration = .milliseconds(250)

  public struct Overlay: Equatable, Sendable {
    public var text: String
    public var underlined: Bool
  }

  private struct Guess {
    let character: Character
    let typedAt: ContinuousClock.Instant
  }

  private var enabled = false
  private var guesses: [Guess] = []
  private var paused = false
  private var alternateScreen = false
  private var scanTail = ""

  public init() {}

  public mutating func roundTripChanged(_ roundTrip: Duration?) {
    guard let roundTrip else { return }
    if !enabled, roundTrip > Self.enableAbove {
      enabled = true
    } else if enabled, roundTrip < Self.disableBelow {
      enabled = false
      guesses = []
    }
  }

  public mutating func typed(_ text: String, at now: ContinuousClock.Instant) {
    for token in TerminalEscapeTokenizer.tokens(text) {
      guard case let .character(character) = token else {
        guesses = []
        continue
      }
      if character == "\u{7F}" || character == "\u{08}" {
        if guesses.popLast() == nil { continue }
      } else if character == "\r" || character == "\n" {
        guesses = []
        paused = false
      } else if isPrintable(character), enabled, !paused, !alternateScreen {
        guesses.append(Guess(character: character, typedAt: now))
      } else {
        guesses = []
      }
    }
  }

  public mutating func received(_ output: String) {
    trackAlternateScreen(output)
    if alternateScreen {
      guesses = []
      return
    }
    for token in TerminalEscapeTokenizer.tokens(output) {
      guard let first = guesses.first else { return }
      guard case let .character(character) = token else { continue }
      if character == first.character {
        guesses.removeFirst()
      } else if isPrintable(character) {
        guesses = []
        return
      }
    }
  }

  @discardableResult
  public mutating func tick(at now: ContinuousClock.Instant) -> Bool {
    guard let oldest = guesses.first, oldest.typedAt.duration(to: now) > Self.glitchAfter else {
      return false
    }
    guesses = []
    paused = true
    return true
  }

  public func overlay(at now: ContinuousClock.Instant) -> Overlay? {
    guard let oldest = guesses.first else { return nil }
    return Overlay(
      text: String(guesses.map(\.character)),
      underlined: oldest.typedAt.duration(to: now) > Self.underlineAfter)
  }

  public var isEnabled: Bool { enabled }

  private func isPrintable(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first else { return false }
    return scalar.value >= 0x20 && scalar.value != 0x7F
  }

  private mutating func trackAlternateScreen(_ output: String) {
    let text = scanTail + output
    scanTail = ""
    var searchStart = text.startIndex
    while let range = text.range(of: "\u{1B}[?", range: searchStart..<text.endIndex) {
      var cursor = range.upperBound
      var parameters = ""
      while cursor < text.endIndex, text[cursor].isNumber || text[cursor] == ";" {
        parameters.append(text[cursor])
        cursor = text.index(after: cursor)
      }
      guard cursor < text.endIndex else {
        if text.distance(from: range.lowerBound, to: text.endIndex) <= 16 {
          scanTail = String(text[range.lowerBound...])
        }
        return
      }
      let final = text[cursor]
      if final == "h" || final == "l" {
        let modes = parameters.split(separator: ";")
        if modes.contains(where: { $0 == "47" || $0 == "1047" || $0 == "1049" }) {
          alternateScreen = final == "h"
        }
      }
      searchStart = text.index(after: cursor)
    }
    for prefix in ["\u{1B}[", "\u{1B}"] where text.hasSuffix(prefix) {
      scanTail = prefix
      return
    }
  }
}
