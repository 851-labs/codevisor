import SwiftUI

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

public enum CodevisorSymbol: String {
  case codevisorMark = "codevisor-mark"
  case gitHubMark = "github-mark"
  case gitBranch = "git-branch"
  case gitBranchCheck = "git-branch-check"
  case gitBranchDot = "git-branch-dot"
  case gitBranchX = "git-branch-x"
  case gitMerge = "git-merge"
  case gitPullRequest = "git-pull-request"
  case gitPullRequestClosed = "git-pull-request-closed"
  case gitPullRequestDraft = "git-pull-request-draft"

  public static let worktreeSystemName = "arrow.trianglehead.branch"

  public var image: Image { Image(rawValue, bundle: .module) }

  public static func harness(_ harnessId: String?, fallback systemName: String) -> Image {
    symbolName("harness", harnessId).map { Image($0, bundle: .module) } ?? Image(systemName: systemName)
  }

  public static func sandboxVendor(_ vendorId: String?) -> Image {
    symbolName("sandbox-vendor", symbolVendor(vendorId)).map { Image($0, bundle: .module) }
      ?? Image(systemName: "shippingbox")
  }

  #if os(macOS)
    public static func harnessImage(_ harnessId: String?) -> NSImage? {
      symbolName("harness", harnessId).flatMap { NSImage(symbolName: $0, bundle: .module, variableValue: 0) }
    }
  #else
    public static func sandboxVendorImage(_ vendorId: String?) -> UIImage? {
      symbolName("sandbox-vendor", symbolVendor(vendorId)).flatMap { UIImage(named: $0, in: .module, with: nil) }
        ?? UIImage(systemName: "shippingbox")
    }
  #endif

  private static func symbolVendor(_ vendorId: String?) -> String? {
    vendorId == "tart-orchard" ? "tart" : vendorId
  }

  private static func symbolName(_ family: String, _ id: String?) -> String? {
    guard let id, !id.isEmpty else { return nil }
    let name = "\(family)-\(id)"
    #if canImport(UIKit)
      return UIImage(named: name, in: .module, with: nil) == nil ? nil : name
    #else
      return NSImage(symbolName: name, bundle: .module, variableValue: 0) == nil ? nil : name
    #endif
  }
}
