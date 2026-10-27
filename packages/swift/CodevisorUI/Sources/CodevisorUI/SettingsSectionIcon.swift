import SwiftUI

public enum SettingsSectionIcon: Sendable {
  case account, machines, sandboxes, projects
  case general, updates, notifications, shortcuts
  case harnesses, skills, plugins
  case developer

  public var systemImage: String {
    switch self {
    case .account: "person.crop.circle.fill"
    case .machines: "desktopcomputer"
    case .sandboxes: "shippingbox.fill"
    case .projects: "folder.fill"
    case .general: "gearshape.fill"
    case .updates: "arrow.down.circle.fill"
    case .notifications: "bell.badge.fill"
    case .shortcuts: "keyboard.fill"
    case .harnesses: "brain.fill"
    case .skills: "book.closed.fill"
    case .plugins: "puzzlepiece.fill"
    case .developer: "hammer.fill"
    }
  }

  var glyphScale: CGFloat {
    switch self {
    case .account, .general, .updates: 1.15
    default: 1
    }
  }

  public var tint: Color {
    switch self {
    case .account: .blue
    case .machines: .indigo
    case .sandboxes: .orange
    case .projects: .cyan
    case .general, .shortcuts: .gray
    case .updates: .green
    case .notifications: .red
    case .harnesses: .pink
    case .skills: .brown
    case .plugins: .purple
    case .developer: Color(white: 0.32)
    }
  }
}

public struct SettingsIconTile: View {
  private let icon: SettingsSectionIcon
  private let size: CGFloat

  public init(_ icon: SettingsSectionIcon, size: CGFloat) {
    self.icon = icon
    self.size = size
  }

  public var body: some View {
    Image(systemName: icon.systemImage)
      .font(.system(size: size * 0.55 * icon.glyphScale, weight: .semibold))
      .imageScale(.medium)
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .background(icon.tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
      .accessibilityHidden(true)
  }
}
