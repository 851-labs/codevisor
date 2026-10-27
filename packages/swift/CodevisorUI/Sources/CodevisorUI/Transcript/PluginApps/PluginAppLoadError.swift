import Foundation

enum PluginAppLoadError: LocalizedError {
  case relayUnavailable
  case unusableAddress

  var errorDescription: String? {
    switch self {
    case .relayUnavailable: "This machine's relay connection isn't available yet. Try again once it reconnects."
    case .unusableAddress: "The server returned an unusable app address."
    }
  }
}
