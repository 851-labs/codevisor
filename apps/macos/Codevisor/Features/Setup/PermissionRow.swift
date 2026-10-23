import AppKit
import CodevisorUI
import SwiftUI

struct PermissionCard<Content: View>: View {
  var embedded = false
  @ViewBuilder var content: Content

  var body: some View {
    if embedded {
      VStack(spacing: 0) { content }
    } else {
      VStack(spacing: 0) { content }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBackgroundColor))
    }
  }
}

struct PermissionRow<Action: View>: View {
  let symbol: String
  let title: String
  var subtitle: String?
  var grantedLabel: String?
  var embedded = false
  @ViewBuilder var action: Action

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: embedded ? 14 : 18, weight: .medium))
        .symbolRenderingMode(.hierarchical)
        .frame(width: embedded ? 26 : 34, height: embedded ? 26 : 34)
        .background(RoundedRectangle(cornerRadius: embedded ? 6 : 8).fill(Color.secondary.opacity(0.12)))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .fontWeight(.medium)
        if let subtitle {
          Text(subtitle)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if let grantedLabel {
        PermissionGrantedBadge(label: grantedLabel)
      } else {
        action
          .controlSize(embedded ? .small : .regular)
      }
    }
    .frame(minHeight: embedded ? 26 : 34)
    .padding(.vertical, embedded ? 7 : 10)
    .animation(.smooth(duration: 0.25), value: grantedLabel)
  }
}

struct PermissionGrantedBadge: View {
  let label: String

  var body: some View {
    Label(label, systemImage: "checkmark.circle.fill")
      .font(.callout.weight(.medium))
      .foregroundStyle(.green)
      .labelStyle(.titleAndIcon)
      .transition(.opacity.combined(with: .scale(scale: 0.9)))
  }
}

struct PermissionActionButton: View {
  let title: String
  let action: () -> Void

  init(_ title: String, action: @escaping () -> Void) {
    self.title = title
    self.action = action
  }

  var body: some View {
    Button(title, action: action)
      .buttonStyle(.bordered)
  }
}

struct AppDragChip: View {
  var large = false
  @State private var isHovered = false

  private var appURL: URL { Bundle.main.bundleURL }

  private var appName: String {
    FileManager.default.displayName(atPath: appURL.path)
  }

  var body: some View {
    HStack(spacing: large ? 10 : 6) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
        .resizable()
        .interpolation(.high)
        .frame(width: large ? 36 : 18, height: large ? 36 : 18)
        .accessibilityHidden(true)
      Text(appName)
        .fontWeight(large ? .medium : nil)
        .lineLimit(1)
      Image(systemName: "hand.draw")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
    .padding(.horizontal, large ? 12 : 8)
    .frame(height: large ? 52 : 24)
    .background(
      RoundedRectangle(cornerRadius: large ? 10 : 6, style: .continuous)
        .fill(Color.secondary.opacity(isHovered ? 0.24 : 0.16))
    )
    .contentShape(RoundedRectangle(cornerRadius: large ? 10 : 6, style: .continuous))
    .onHover { isHovered = $0 }
    .onDrag { NSItemProvider(object: appURL as NSURL) }
    .help("Drag Codevisor into the Full Disk Access list")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(appName)
    .accessibilityHint("Drag onto the Full Disk Access list in System Settings")
  }
}
