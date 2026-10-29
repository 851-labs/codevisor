enum GenerateError: Error, CustomStringConvertible {
  case hashMismatch(Int)
  case pngUnavailable(String)

  var description: String {
    switch self {
    case .hashMismatch(let count): "\(count) version(s) don't match the player's pixels"
    case .pngUnavailable(let path): "Could not write \(path)"
    }
  }
}
