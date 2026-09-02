import SwiftUI

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
