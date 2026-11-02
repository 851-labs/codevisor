import SwiftUI

#if os(macOS)
  import AppKit

  public struct CodevisorAppIconView: View {
    private let size: CGFloat

    public init(size: CGFloat) {
      self.size = size
    }

    public var body: some View {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.18), radius: 9, y: 5)
        .accessibilityHidden(true)
    }
  }
#else
  import UIKit

  public struct CodevisorAppIconView: View {
    private let size: CGFloat

    @State private var icon = AppIconImage.loaded

    public init(size: CGFloat) {
      self.size = size
    }

    public var body: some View {
      Group {
        switch icon {
        case let .found(appIcon):
          Image(uiImage: appIcon)
            .resizable()
            .interpolation(.high)
        case .missing:
          CodevisorSymbol.codevisorMark.image
            .font(.system(size: size * 0.69))
            .foregroundStyle(.tint)
        case nil:
          Color.clear
        }
      }
      .scaledToFit()
      .frame(width: size, height: size)
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

    @MainActor static var loaded: AppIconImage?

    @MainActor
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
      return largest.map { $0.preparingForDisplay() ?? $0 }
    }
  }
#endif
