import AppKit
import CodevisorCore
import SwiftUI

struct ChromeExtensionFileChip: View {
  let controller: SessionController

  @State private var archiveURL: URL?
  @State private var icon: NSImage?
  @State private var isHovered = false

  var body: some View {
    Group {
      if let archiveURL {
        HStack(spacing: 6) {
          Image(nsImage: icon ?? NSWorkspace.shared.icon(forFile: archiveURL.path))
            .resizable()
            .interpolation(.high)
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
          Text("Codevisor.zip")
            .lineLimit(1)
          Image(systemName: "hand.draw")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.secondary.opacity(isHovered ? 0.24 : 0.16))
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { isHovered = $0 }
        .onDrag { NSItemProvider(contentsOf: archiveURL) ?? NSItemProvider() }
        .help("Drag the Codevisor extension into Chrome")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Codevisor extension")
        .accessibilityHint("Drag onto Chrome’s Extensions page")
      } else {
        ProgressView().controlSize(.small)
      }
    }
    .task {
      guard archiveURL == nil, let archive = try? await controller.browserExtensionArchive() else { return }
      if let iconURL = try? await controller.browserExtensionIcon() {
        icon = NSImage(contentsOf: iconURL)
      }
      archiveURL = archive
    }
  }
}
