import CodevisorCore
import Foundation

enum MarkdownDocumentLoadError: Error {
  case unsupportedEncoding
}

/// Human-readable recovery guidance for document loading failures.
struct MarkdownDocumentFailure {
  let title: String
  let message: String

  init(error: any Error, path: String) {
    let name = (path as NSString).lastPathComponent
    let code = serverErrorCode(error)
    let status: Int?
    if case let CodevisorServerClientError.httpStatus(value, _) = error {
      status = value
    } else {
      status = nil
    }

    if error is MarkdownDocumentLoadError {
      title = "Can’t read this document"
      message = "\(name) isn’t in a supported text format. Try saving it as UTF-8."
    } else {
      if code == "not_found" || status == 404 {
        title = "File not found"
        message = "\(name) may have been moved, renamed, or deleted."
      } else if code == "permission_denied" || status == 403 {
        title = "Can’t access this file"
        message = "Codevisor doesn’t have permission to read \(name). Check its permissions, then try again."
      } else if status == 401 {
        title = "Connection needs attention"
        message = "Reconnect to this machine in Settings, then try again."
      } else if code == "not_a_file" {
        title = "This link points to a folder"
        message = "Open a link to a Markdown file to preview it here."
      } else if Self.isConnectionFailure(error) || [502, 503, 504].contains(status ?? 0) {
        title = "Can’t connect to this machine"
        message = "Make sure it’s online and Codevisor is running, then try again."
      } else {
        title = "Can’t open this document"
        message = "Something went wrong while opening \(name). Try again in a moment."
      }
    }
  }

  private static func isConnectionFailure(_ error: any Error) -> Bool {
    if error is MachineUnreachableError || error is ServerRequestGateError { return true }
    guard let error = error as? URLError else { return false }
    switch error.code {
    case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost,
      .timedOut, .secureConnectionFailed, .cannotLoadFromNetwork, .notConnectedToInternet,
      .internationalRoamingOff, .dataNotAllowed:
      return true
    default:
      return false
    }
  }
}
