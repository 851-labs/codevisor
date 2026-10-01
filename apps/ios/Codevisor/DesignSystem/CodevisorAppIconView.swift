import SwiftUI
import UIKit

/// The primary app icon Xcode compiled for this bundle, rendered as regular
/// SwiftUI content. Development builds automatically use their generated
/// worktree icon; release builds use the production icon.
///
/// The icon files are found, read and decoded off the main thread the first
/// time any instance appears (the launch splash), then shared.
struct CodevisorAppIconView: View {
  let size: CGFloat

  @State private var icon = AppIconImage.loaded

  var body: some View {
    Group {
      switch icon {
      case let .found(appIcon):
        Image(uiImage: appIcon)
          .resizable()
          .interpolation(.high)
      case .missing:
        Image("hunk")
          .resizable()
          .foregroundStyle(.tint)
      case nil:
        Color.clear
      }
    }
    .scaledToFit()
    .frame(width: size, height: size)
    // SpringBoard applies this continuous app-icon presentation mask; the
    // compiled artwork loaded as a UIImage does not include the final mask.
    .clipShape(
      RoundedRectangle(
        cornerRadius: size * 0.224,
        style: .continuous
      )
    )
    .accessibilityHidden(true)
    .task {
      guard icon == nil else { return }
      let loaded = await AppIconImage.load()
      withAnimation(.easeOut(duration: 0.15)) { icon = loaded }
    }
  }
}

private enum AppIconImage: Equatable {
  case found(UIImage)
  case missing

  /// Set on the main actor once the first load finishes.
  @MainActor static var loaded: AppIconImage?

  static func load() async -> AppIconImage {
    if let loaded { return loaded }
    let image = await decodeLargestIcon()
    let result: AppIconImage = image.map { .found($0) } ?? .missing
    loaded = result
    return result
  }

  @concurrent
  nonisolated private static func decodeLargestIcon() async -> UIImage? {
    let bundle = Bundle.main
    let icons =
      bundle.object(forInfoDictionaryKey: "CFBundleIcons")
      as? [String: Any]
    let primaryIcon = icons?["CFBundlePrimaryIcon"] as? [String: Any]
    guard let fileNames = primaryIcon?["CFBundleIconFiles"] as? [String],
      let resourceURLs = bundle.urls(
        forResourcesWithExtension: "png",
        subdirectory: nil
      )
    else { return nil }

    // Icon Composer catalogs are valid app icons but are not regular image
    // assets: asking UIImage(named:) for their catalog name throws an
    // Objective-C exception. Load the rendered icon file directly instead.
    let images =
      resourceURLs
      .filter { url in
        fileNames.contains { fileName in
          url.deletingPathExtension().lastPathComponent
            .hasPrefix(fileName)
        }
      }
      .compactMap { UIImage(contentsOfFile: $0.path) }
    let largest = images.max { lhs, rhs in
      let lhsWidth = lhs.cgImage?.width ?? 0
      let rhsWidth = rhs.cgImage?.width ?? 0
      return lhsWidth < rhsWidth
    }
    // Decode now, here, rather than at first draw on the main thread.
    return largest.map { $0.preparingForDisplay() ?? $0 }
  }
}
