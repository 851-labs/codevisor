import SwiftUI

/// The "PDF" tag shown over document attachment previews so they read
/// differently from plain images. Shared by the iOS transcript/composer and
/// the macOS attachment views — one implementation so sizing and styling
/// changes land everywhere at once.
public struct PDFBadge: View {
    public init() {}

    public var body: some View {
        Text("PDF")
            // `.caption2` resolves to the HIG minimum legible size on each
            // platform (11 pt iOS / 10 pt macOS) and scales with Dynamic Type.
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.55)))
            .padding(4)
            .allowsHitTesting(false)
    }
}

/// The play glyph overlaid on video attachment thumbnails.
public struct VideoPlayBadge: View {
    public init() {}

    public var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Circle().fill(.black.opacity(0.6)))
            .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
            .allowsHitTesting(false)
    }
}
