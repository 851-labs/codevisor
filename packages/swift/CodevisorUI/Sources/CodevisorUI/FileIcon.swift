import Foundation
import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif

/// One file identity shared by browser rows, search results, and workspace panes.
public struct FileIcon: View {
  private let path: String
  private let isDirectory: Bool
  private let size: CGFloat

  public init(path: String, isDirectory: Bool = false, size: CGFloat = 18) {
    self.path = path
    self.isDirectory = isDirectory
    self.size = size
  }

  public var body: some View {
    Group {
      if isDirectory {
        Image(systemName: "folder.fill")
          .resizable().scaledToFit().foregroundStyle(.tint)
      } else if let name = FileIconCatalog.assetName(for: path) {
        Image(name, bundle: .module)
          .resizable().scaledToFit().foregroundStyle(.secondary)
      } else {
        Image(systemName: "text.document")
          .resizable().scaledToFit().foregroundStyle(.secondary)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  #if canImport(AppKit)
    static func nativeImage(for path: String) -> NSImage? {
      if let name = FileIconCatalog.assetName(for: path), let image = Bundle.module.image(forResource: name) {
        return image
      }
      return NSImage(systemSymbolName: "text.document", accessibilityDescription: nil)
    }
  #endif
}

/// Pure filename matching; never consults the local filesystem for remote paths.
enum FileIconCatalog {
  private struct Associations: Decodable, Sendable {
    let fileNames: [String: String]
    let fileExtensions: [String: String]
  }

  private static let associations: Associations = {
    guard let url = Bundle.module.url(forResource: "associations", withExtension: "json", subdirectory: "FileIcons"),
      let data = try? Data(contentsOf: url),
      let result = try? JSONDecoder().decode(Associations.self, from: data)
    else {
      assertionFailure("Missing bundled file icon associations")
      return Associations(fileNames: [:], fileExtensions: [:])
    }
    return result
  }()

  static func assetName(for path: String) -> String? {
    let name = (path as NSString).lastPathComponent.lowercased()
    if let icon = associations.fileNames[name] { return "file_type_" + icon }
    // Longest suffix wins: component.spec.ts precedes spec.ts, which precedes ts.
    for dot in name.indices where name[dot] == "." {
      let suffix = String(name[name.index(after: dot)...])
      if let icon = associations.fileExtensions[suffix] { return "file_type_" + icon }
    }
    return nil
  }
}
