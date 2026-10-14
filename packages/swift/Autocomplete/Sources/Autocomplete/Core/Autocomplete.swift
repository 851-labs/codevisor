public enum Autocomplete {}

extension Autocomplete {
  enum KeyCommand: Sendable, Hashable {
    case moveUp, moveDown, moveToFirst, moveToLast, accept, dismiss
  }
}
