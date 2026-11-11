import Foundation

@MainActor
final class StandardizedPathMemo {
  private var lastPath: String?
  private var lastStandardized = ""

  func standardized(_ path: String) -> String {
    if path == lastPath { return lastStandardized }

    lastPath = path
    lastStandardized = URL(fileURLWithPath: path).standardizedFileURL.path
    return lastStandardized
  }
}
