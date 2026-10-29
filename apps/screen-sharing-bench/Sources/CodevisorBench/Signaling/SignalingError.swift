import Darwin

enum SignalingError: Error, CustomStringConvertible {
  case system(call: String, errno: Int32)
  case closed
  case timedOut(String)
  case invalidAddress(String)

  var description: String {
    switch self {
    case .system(let call, let errno): "\(call) failed: \(String(cString: strerror(errno)))"
    case .closed: "the other Mac closed the signaling connection"
    case .timedOut(let what): "timed out \(what)"
    case .invalidAddress(let host): "\(host) is not an IPv4 address"
    }
  }
}
