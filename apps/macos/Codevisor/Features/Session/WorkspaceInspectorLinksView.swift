import AppKit
import CodevisorClient
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorLinksView: View {
  let model: WorkspaceInspectorMediaModel
  let client: any CodevisorServerClienting
  let onOpen: (WorkspaceInspectorView.Destination) -> Void
  let onRetry: () -> Void

  var body: some View {
    if model.links.isEmpty {
      WorkspaceInspectorMediaPlaceholder(
        phase: model.linksPhase, emptyTitle: "No Links", systemImage: "link",
        emptyDescription: "Links mentioned in this workspace's chats appear here.",
        onRetry: onRetry
      )
    } else {
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
          ForEach(model.links) { link in
            WorkspaceInspectorLinkCard(link: link, client: client) {
              onOpen(.link(link.url))
            }
          }
        }
        .padding(12)
        footer
      }
    }
  }

  @ViewBuilder private var footer: some View {
    if case let .failed(message) = model.linksPhase {
      HStack {
        Text("Couldn't load links: \(message)")
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Spacer()
        Button("Try Again", action: onRetry)
      }
      .padding([.horizontal, .bottom], 12)
    } else if model.hasMoreLinks {
      ProgressView()
        .controlSize(.small)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
        .task(id: "\(model.linksNextBefore ?? ""):\(model.linksPhase == .loaded)") {
          await model.loadMoreLinks()
        }
    }
  }
}

@MainActor
private final class WorkspaceInspectorLinkPreview {
  static let cache = NSCache<NSURL, WorkspaceInspectorLinkPreview>()

  let preview: ServerLinkPreview
  let image: NSImage?

  init(preview: ServerLinkPreview, image: NSImage?) {
    self.preview = preview
    self.image = image
  }

  static func load(_ url: URL, client: any CodevisorServerClienting) async -> WorkspaceInspectorLinkPreview? {
    if let cached = cache.object(forKey: url as NSURL) { return cached }
    guard let preview = try? await client.linkPreview(url: url) else { return nil }
    let data = preview.image == nil ? nil : try? await client.linkPreviewImage(url: url)
    guard !Task.isCancelled else { return nil }
    let loaded = WorkspaceInspectorLinkPreview(preview: preview, image: data.flatMap(NSImage.init(data:)))
    cache.setObject(loaded, forKey: url as NSURL)
    return loaded
  }
}

private struct WorkspaceInspectorLinkCard: View {
  let link: ServerWorkspaceLink
  let client: any CodevisorServerClienting
  let onOpen: () -> Void

  @State private var loaded: WorkspaceInspectorLinkPreview?

  private static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

  private var current: WorkspaceInspectorLinkPreview? {
    loaded ?? WorkspaceInspectorLinkPreview.cache.object(forKey: link.url as NSURL)
  }

  private var title: String {
    current?.preview.title ?? link.title ?? WorkspaceInspectorLinksView.host(link.url)
  }

  private var tint: (red: Double, green: Double, blue: Double)? {
    guard current?.image != nil, let hex = current?.preview.image?.color else { return nil }
    return Self.rgb(hex)
  }

  var body: some View {
    Button(action: onOpen) {
      VStack(spacing: 0) {
        Color.clear
          .aspectRatio(1.15, contentMode: .fit)
          .overlay { artwork }
          .clipped()
          .background(.fill.quaternary)
        caption
      }
      .clipShape(Self.shape)
      .contentShape(Self.shape)
    }
    .buttonStyle(.plain)
    .help(link.url.absoluteString)
    .accessibilityLabel(title)
    .accessibilityValue(WorkspaceInspectorLinksView.host(link.url))
    .contextMenu {
      Button("Copy Link") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
      }
      Button("Open in Default Browser") {
        NSWorkspace.shared.open(link.url)
      }
    }
    .task(id: link.url) {
      guard loaded == nil, let result = await WorkspaceInspectorLinkPreview.load(link.url, client: client) else {
        return
      }
      loaded = result
    }
  }

  @ViewBuilder private var artwork: some View {
    if let image = current?.image {
      Image(nsImage: image)
        .resizable()
        .scaledToFill()
    } else if let description = current?.preview.description {
      Text(description)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      WorkspaceInspectorSiteIcon(url: link.url, client: client)
        .frame(width: 28, height: 28)
    }
  }

  private var caption: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title)
        .font(.callout.weight(.semibold))
        .lineLimit(1)
      Text(WorkspaceInspectorLinksView.host(link.url))
        .font(.caption)
        .lineLimit(1)
        .opacity(0.7)
    }
    .foregroundStyle(captionForeground)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background {
      if let tint {
        Color(red: tint.red, green: tint.green, blue: tint.blue)
      } else {
        Rectangle().fill(.fill.tertiary)
      }
    }
  }

  private var captionForeground: Color {
    guard let tint else { return .primary }
    let luminance = 0.2126 * tint.red + 0.7152 * tint.green + 0.0722 * tint.blue
    return luminance > 0.6 ? .black : .white
  }

  private static func rgb(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
    guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
    return (
      Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255
    )
  }
}

extension WorkspaceInspectorLinksView {
  fileprivate static func host(_ url: URL) -> String {
    guard let host = url.host() else { return BrowserLocation.display(url) }
    return url.port.map { "\(host):\($0)" } ?? host
  }
}

private struct WorkspaceInspectorSiteIcon: View {
  private static let cache = NSCache<NSString, NSImage>()

  let url: URL
  let client: any CodevisorServerClienting
  @Environment(\.colorScheme) private var colorScheme
  @State private var image: NSImage?

  private var origin: String? {
    guard let scheme = url.scheme, let host = url.host() else { return nil }
    return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
  }

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().scaledToFit()
      } else {
        Image(systemName: "globe").foregroundStyle(.secondary)
      }
    }
    .task(id: "\(origin ?? ""):\(colorScheme == .dark)") {
      guard let origin else { return }
      let key = "\(origin):\(colorScheme == .dark)" as NSString
      if let cached = Self.cache.object(forKey: key) {
        image = cached
        return
      }
      guard let data = try? await client.toolIcon(.site(origin: origin, dark: colorScheme == .dark)),
        let loaded = NSImage(data: data)
      else { return }
      Self.cache.setObject(loaded, forKey: key)
      image = loaded
    }
  }
}
