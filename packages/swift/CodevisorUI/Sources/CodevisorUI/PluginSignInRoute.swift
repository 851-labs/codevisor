import CodevisorCore
import Foundation

public enum PluginSignInRoute {
  case thisMachine
  case localMachine(any CodevisorServerClienting)
  case unavailable
}

enum PluginSignInError: LocalizedError {
  case needsMac(plugin: String)
  case notOnThisMac(plugin: String)

  var errorDescription: String? {
    switch self {
    case let .needsMac(plugin):
      "Sign in to \(plugin) from Codevisor on your Mac. The sign-in then works on your other machines too."
    case let .notOnThisMac(plugin):
      "\(plugin) isn't on this Mac. Turn it on here to sign in, and the sign-in reaches your other machines too."
    }
  }
}

extension ServerMcpServer {
  func isSamePlugin(as other: ServerMcpServer) -> Bool {
    if let catalogId, catalogId == other.catalogId { return true }
    return name == other.name
  }
}
