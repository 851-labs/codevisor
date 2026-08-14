import SwiftUI
import UIKit

/// The primary app icon Xcode compiled for this bundle, rendered as regular
/// SwiftUI content. Development builds automatically use their generated
/// worktree icon; release builds use the production icon.
struct CodevisorAppIconView: View {
    let size: CGFloat

    private static let appIcon: UIImage? = {
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
        return images.max { lhs, rhs in
            let lhsWidth = lhs.cgImage?.width ?? 0
            let rhsWidth = rhs.cgImage?.width ?? 0
            return lhsWidth < rhsWidth
        }
    }()

    var body: some View {
        Group {
            if let appIcon = Self.appIcon {
                Image(uiImage: appIcon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image("hunk")
                    .resizable()
                    .foregroundStyle(.tint)
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
    }
}
