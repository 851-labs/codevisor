import SwiftUI

/// Artwork for a not-yet-installed registry plugin: the repo owner's GitHub
/// avatar in an app-icon-style rounded rect, with an SF Symbol placeholder
/// while loading or when the entry carries no avatar. Installed plugins keep
/// using `PluginIconView`, which renders the plugin's own served artwork.
public struct PluginRegistryAvatarView: View {
    private let url: URL?
    private let size: CGFloat
    private let fallbackSystemName: String

    public init(url: URL?, size: CGFloat, fallbackSystemName: String = "puzzlepiece.extension") {
        self.url = url
        self.size = size
        self.fallbackSystemName = fallbackSystemName
    }

    public init(
        urlString: String?,
        size: CGFloat,
        fallbackSystemName: String = "puzzlepiece.extension"
    ) {
        self.init(
            url: urlString.flatMap(URL.init(string:)),
            size: size,
            fallbackSystemName: fallbackSystemName
        )
    }

    public var body: some View {
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary.opacity(0.5))
            Image(systemName: fallbackSystemName)
                .font(.system(size: size * 0.45))
                .foregroundStyle(.secondary)
        }
    }
}
