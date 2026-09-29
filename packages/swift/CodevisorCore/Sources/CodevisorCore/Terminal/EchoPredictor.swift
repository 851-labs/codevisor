import Foundation

/// Local echo for slow links, in the spirit of Mosh's predictive echo
/// (reimplemented from its published behavior; no Mosh code is used).
///
/// When the round trip to the server is long enough to feel, the characters
/// the user types are shown at the cursor right away, before the shell's echo
/// arrives, and are dropped as the real echo confirms them. The predictor
/// only decides *what* to show; the renderer draws it as an overlay, so the
/// terminal's own state never holds a guess.
///
/// It stays conservative:
/// - on only while the smoothed round trip is above `enableAbove` (and off
///   again below `disableBelow`, so it doesn't flicker around one value);
/// - only printable text and backspace over its own pending guesses —
///   anything else (Enter, control keys, escape sequences) ends the line of
///   guesses, since what it does depends on the program;
/// - never while a full-screen program has the alternate screen;
/// - a guess the server doesn't confirm within `glitchAfter` (a password
///   prompt, a program that doesn't echo) clears all guesses and pauses
///   predicting until the next line.
public struct EchoPredictor: Sendable {
  public static let enableAbove: Duration = .milliseconds(30)
  public static let disableBelow: Duration = .milliseconds(20)
  /// Guesses outstanding this long are underlined, so the user can tell
  /// they aren't confirmed yet.
  public static let underlineAfter: Duration = .milliseconds(80)
  public static let glitchAfter: Duration = .milliseconds(250)

  /// What the renderer shows at the cursor.
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
  /// Set after a glitch until the next line (Enter), when the program may
  /// be one that echoes again.
  private var paused = false
  private var alternateScreen = false
  /// Output bytes carried between chunks while scanning for a split mode
  /// escape sequence.
  private var scanTail = ""

  public init() {}

  /// Updates the enablement hysteresis from the transport's round trip.
  public mutating func roundTripChanged(_ roundTrip: Duration?) {
    guard let roundTrip else { return }
    if !enabled, roundTrip > Self.enableAbove {
      enabled = true
    } else if enabled, roundTrip < Self.disableBelow {
      enabled = false
      guesses = []
    }
  }

  /// The user typed `text` (as sent to the server).
  public mutating func typed(_ text: String, at now: ContinuousClock.Instant) {
    for token in Self.tokens(text) {
      guard case let .character(character) = token else {
        // A key sent as an escape sequence (arrows, function keys): what it
        // does depends on the program.
        guesses = []
        continue
      }
      if character == "\u{7F}" || character == "\u{08}" {
        // Backspace can only safely undo a guess of our own.
        if guesses.popLast() == nil { continue }
      } else if character == "\r" || character == "\n" {
        guesses = []
        paused = false
      } else if isPrintable(character), enabled, !paused, !alternateScreen {
        guesses.append(Guess(character: character, typedAt: now))
      } else {
        // Control keys, escape sequences, or not predicting: whatever is on
        // screen from here on comes from the server.
        guesses = []
      }
    }
  }

  /// Output arrived from the server. Confirms guesses its text echoes and
  /// tracks whether a full-screen program has the alternate screen.
  public mutating func received(_ output: String) {
    trackAlternateScreen(output)
    if alternateScreen {
      guesses = []
      return
    }
    for token in Self.tokens(output) {
      guard let first = guesses.first else { return }
      // Escape sequences (cursor moves, colors, redraws) around an echo are
      // expected.
      guard case let .character(character) = token else { continue }
      if character == first.character {
        guesses.removeFirst()
      } else if isPrintable(character) {
        // The screen got something other than the guess: the program isn't
        // echoing what was typed, so the guesses are wrong.
        guesses = []
        return
      }
    }
  }

  /// Ages the guesses. Returns true if a glitch just cleared them.
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

  private enum Token {
    case character(Character)
    case escapeSequence
  }

  /// Splits text into characters and whole escape sequences (CSI, OSC, and
  /// two-character escapes). An unfinished sequence at the end counts as one.
  private static func tokens(_ text: String) -> [Token] {
    var tokens: [Token] = []
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      index = text.index(after: index)
      guard character == "\u{1B}" else {
        tokens.append(.character(character))
        continue
      }
      tokens.append(.escapeSequence)
      guard index < text.endIndex else { break }
      let kind = text[index]
      index = text.index(after: index)
      if kind == "[" {
        // CSI: parameters and intermediates, then a final byte @...~.
        while index < text.endIndex {
          let scalar = text[index].unicodeScalars.first!.value
          index = text.index(after: index)
          if (0x40...0x7E).contains(scalar) { break }
        }
      } else if kind == "]" || kind == "P" || kind == "_" {
        // OSC / DCS / APC: until BEL or ST (ESC \).
        while index < text.endIndex {
          let next = text[index]
          index = text.index(after: index)
          if next == "\u{07}" { break }
          if next == "\u{1B}", index < text.endIndex, text[index] == "\\" {
            index = text.index(after: index)
            break
          }
        }
      }
    }
    return tokens
  }

  private func isPrintable(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first else { return false }
    return scalar.value >= 0x20 && scalar.value != 0x7F
  }

  /// DECSET/DECRST 47, 1047, 1049: alternate screen on or off.
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
        // Unfinished: finish it with the next chunk (bounded, in case it
        // was never a mode sequence at all).
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
    // A lone ESC or "ESC [" at the very end may start a mode sequence.
    for prefix in ["\u{1B}[", "\u{1B}"] where text.hasSuffix(prefix) {
      scanTail = prefix
      return
    }
  }
}
