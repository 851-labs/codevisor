import Foundation
import SwiftUI

/// One file identity shared by browser rows, search results, and workspace panes.
/// On an emphasized selection (a selected row in a key window) every icon
/// turns white, as Finder's and Xcode's do.
public struct FileIcon: View {
  @Environment(\.backgroundProminence) private var prominence
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
          .resizable().scaledToFit().foregroundStyle(isOnSelection ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
      } else if let name = FileIconCatalog.assetName(for: path) {
        Image(name, bundle: .module)
          .renderingMode(isOnSelection ? .template : nil)
          .resizable().scaledToFit().foregroundStyle(isOnSelection ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
      } else {
        Image(systemName: "text.document")
          .resizable().scaledToFit().foregroundStyle(isOnSelection ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  private var isOnSelection: Bool { prominence == .increased }
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
