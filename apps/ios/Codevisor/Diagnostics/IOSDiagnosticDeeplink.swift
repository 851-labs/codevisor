import Foundation

#if DEBUG || NAVIGATION_DIAGNOSTICS
  /// Deeplinks that drive the app for diagnostics builds without desktop
  /// automation of the Simulator. Production builds do not compile them.
  ///
  /// - `<scheme>://diagnostic-new-chat?text=hello` presents the New Chat
  ///   sheet and pre-fills the composer.
  /// - `<scheme>://diagnostic-send` taps the composer's send button (the
  ///   real button path, not a controller call).
  /// - `<scheme>://diagnostic-open-session?id=<uuid>` opens a persisted chat.
  enum IOSDiagnosticDeeplink: Equatable {
    case newChat(text: String)
    case send
    case openSession(UUID)

    static func parse(_ url: URL) -> IOSDiagnosticDeeplink? {
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
      switch url.host {
      case "diagnostic-new-chat":
        return .newChat(text: value("text") ?? "")
      case "diagnostic-send":
        return .send
      case "diagnostic-open-session":
        return value("id").flatMap(UUID.init(uuidString:)).map { .openSession($0) }
      default:
        return nil
      }
    }
  }

  extension Notification.Name {
    /// Posted by the send diagnostic deeplink; the composer that holds text
    /// submits exactly as if its send button were tapped.
    static let codevisorDiagnosticSubmitComposer = Notification.Name(
      "codevisor.diagnostic.submit-composer")
  }
#endif
