import Foundation

enum DelimitedTextTable {
  static func rows(in text: String, delimiter: Character) -> [[String]]? {
    var scanner = Scanner(delimiter: delimiter)
    var characters = text.makeIterator()
    while let character = characters.next() {
      scanner.read(character, peeking: &characters)
    }
    return scanner.finish()
  }

  private struct Scanner {
    let delimiter: Character
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var isQuoted = false

    init(delimiter: Character) {
      self.delimiter = delimiter
    }

    mutating func read(_ character: Character, peeking characters: inout String.Iterator) {
      if isQuoted {
        readQuoted(character, peeking: &characters)
        return
      }
      switch character {
      case "\"" where field.isEmpty: isQuoted = true
      case delimiter: endField()
      case "\n", "\r", "\r\n": endRow()
      default: field.append(character)
      }
    }

    mutating func finish() -> [[String]]? {
      guard !isQuoted else { return nil }
      if !field.isEmpty || !row.isEmpty { endRow() }
      let filled = rows.filter { $0 != [""] }
      return filled.isEmpty ? nil : filled
    }

    private mutating func readQuoted(_ character: Character, peeking characters: inout String.Iterator) {
      guard character == "\"" else {
        field.append(character)
        return
      }
      var lookahead = characters
      guard lookahead.next() == "\"" else {
        isQuoted = false
        return
      }
      characters = lookahead
      field.append("\"")
    }

    private mutating func endField() {
      row.append(field)
      field = ""
    }

    private mutating func endRow() {
      endField()
      rows.append(row)
      row = []
    }
  }
}
