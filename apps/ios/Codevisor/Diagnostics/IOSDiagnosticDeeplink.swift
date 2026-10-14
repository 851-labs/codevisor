import Foundation

#if DEBUG || NAVIGATION_DIAGNOSTICS
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
    static let codevisorDiagnosticSubmitComposer = Notification.Name(
      "codevisor.diagnostic.submit-composer")
  }
#endif
