enum StillError: Error, CustomStringConvertible {
  case unwritable(String)
  case unreadable(String)

  var description: String {
    switch self {
    case .unwritable(let path): "couldn't write a still to \(path)"
    case .unreadable(let path): "couldn't read the still \(path)"
    }
  }
}
