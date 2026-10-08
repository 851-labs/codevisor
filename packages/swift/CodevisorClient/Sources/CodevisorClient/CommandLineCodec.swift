import Foundation

public enum CommandLineCodec {
  public enum ParseError: LocalizedError, Equatable {
    case trailingEscape
    case unterminatedSingleQuote
    case unterminatedDoubleQuote

    public var errorDescription: String? {
      switch self {
      case .trailingEscape: "The command ends with an incomplete escape."
      case .unterminatedSingleQuote: "The command has an unterminated single quote."
      case .unterminatedDoubleQuote: "The command has an unterminated double quote."
      }
    }
  }

  public static func parse(_ commandLine: String) throws -> [String] {
    var parser = Parser()
    for character in commandLine {
      parser.consume(character)
    }
    return try parser.finish()
  }

  private struct Parser {
    private enum Quote { case none, single, double }

    private var result: [String] = []
    private var current = ""
    private var quote = Quote.none
    private var isEscaping = false
    private var hasStartedToken = false

    mutating func consume(_ character: Character) {
      if isEscaping {
        current.append(character)
        isEscaping = false
        hasStartedToken = true
        return
      }

      switch quote {
      case .single: consumeSingleQuoted(character)
      case .double: consumeDoubleQuoted(character)
      case .none: consumeUnquoted(character)
      }
    }

    private mutating func consumeSingleQuoted(_ character: Character) {
      if character == "'" {
        quote = .none
      } else {
        current.append(character)
      }
    }

    private mutating func consumeDoubleQuoted(_ character: Character) {
      if character == "\"" {
        quote = .none
      } else if character == "\\" {
        isEscaping = true
      } else {
        current.append(character)
      }
    }

    private mutating func consumeUnquoted(_ character: Character) {
      if character.isWhitespace {
        if hasStartedToken {
          result.append(current)
          current = ""
          hasStartedToken = false
        }
      } else if character == "'" {
        quote = .single
        hasStartedToken = true
      } else if character == "\"" {
        quote = .double
        hasStartedToken = true
      } else if character == "\\" {
        isEscaping = true
        hasStartedToken = true
      } else {
        current.append(character)
        hasStartedToken = true
      }
    }

    mutating func finish() throws -> [String] {
      if isEscaping { throw ParseError.trailingEscape }
      switch quote {
      case .single: throw ParseError.unterminatedSingleQuote
      case .double: throw ParseError.unterminatedDoubleQuote
      case .none: break
      }
      if hasStartedToken { result.append(current) }
      return result
    }
  }

  public static func format(_ components: [String]) -> String {
    components.map(quote).joined(separator: " ")
  }

  private static func quote(_ component: String) -> String {
    guard !component.isEmpty else { return "''" }
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_@%+=:,./-"))
    if component.unicodeScalars.allSatisfy(safe.contains) { return component }
    return "'" + component.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
  }
}
