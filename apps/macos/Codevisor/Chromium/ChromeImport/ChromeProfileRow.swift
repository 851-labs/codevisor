import AppKit
import CodevisorCoreMac
import SwiftUI

struct ChromeProfileRow: View {
  let profile: ChromeProfile
  let selected: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      HStack(spacing: 12) {
        ChromeProfilePicture(profile: profile)
        Text(profile.name)
          .fontWeight(.medium)
          .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "checkmark")
          .fontWeight(.semibold)
          .foregroundStyle(.tint)
          .opacity(selected ? 1 : 0)
      }
      .frame(minHeight: 34)
      .padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct ChromeProfilePicture: View {
  let profile: ChromeProfile
  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().scaledToFill().clipShape(Circle())
      } else {
        Image(systemName: "person.fill")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Circle().fill(Color.secondary.opacity(0.12)))
      }
    }
    .frame(width: 34, height: 34)
    .accessibilityHidden(true)
    .task(id: profile.id) { image = await Self.load(profile.picture) }
  }

  @concurrent
  private nonisolated static func load(_ url: URL?) async -> NSImage? {
    url.flatMap { NSImage(contentsOf: $0) }
  }
}
