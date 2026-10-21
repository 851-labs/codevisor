import SwiftUI

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

public enum CodevisorSymbol: String {
  case gitHubMark = "github-mark"
  case gitMerge = "git-merge"
  case gitPullRequest = "git-pull-request"
  case gitPullRequestClosed = "git-pull-request-closed"
  case gitPullRequestDraft = "git-pull-request-draft"

  public var image: Image { Image(rawValue, bundle: .module) }

  public static func harness(_ harnessId: String?, fallback systemName: String) -> Image {
    harnessSymbolName(harnessId).map { Image($0, bundle: .module) } ?? Image(systemName: systemName)
  }

  #if os(macOS)
    public static func harnessImage(_ harnessId: String?) -> NSImage? {
      harnessSymbolName(harnessId).flatMap { NSImage(symbolName: $0, bundle: .module, variableValue: 0) }
    }
  #endif

  private static func harnessSymbolName(_ harnessId: String?) -> String? {
    guard let harnessId, !harnessId.isEmpty else { return nil }
    let name = "harness-\(harnessId)"
    #if canImport(UIKit)
      return UIImage(named: name, in: .module, with: nil) == nil ? nil : name
    #else
      return NSImage(symbolName: name, bundle: .module, variableValue: 0) == nil ? nil : name
    #endif
  }
}
