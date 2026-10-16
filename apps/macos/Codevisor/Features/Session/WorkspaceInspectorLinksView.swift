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
      Form {
        Section {
          ForEach(model.links) { link in
            WorkspaceInspectorLinkRow(link: link, client: client) {
              onOpen(.link(link.url))
            }
          }
          if case let .failed(message) = model.linksPhase {
            HStack {
              Text("Couldn't load links: \(message)")
                .foregroundStyle(.secondary)
                .lineLimit(2)
              Spacer()
              Button("Try Again", action: onRetry)
            }
          } else if model.hasMoreLinks {
            ProgressView()
              .controlSize(.small)
              .frame(maxWidth: .infinity)
              .task(id: "\(model.linksNextBefore ?? ""):\(model.linksPhase == .loaded)") {
                await model.loadMoreLinks()
              }
          }
        }
      }
      .formStyle(.grouped)
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

private struct WorkspaceInspectorLinkRow: View {
  let link: ServerWorkspaceLink
  let client: any CodevisorServerClienting
  let onOpen: () -> Void

  @State private var loaded: WorkspaceInspectorLinkPreview?

  private var current: WorkspaceInspectorLinkPreview? {
    loaded ?? WorkspaceInspectorLinkPreview.cache.object(forKey: link.url as NSURL)
  }

  private var title: String {
    current?.preview.title ?? link.title ?? WorkspaceInspectorLinksView.host(link.url)
  }

  var body: some View {
    Button(action: onOpen) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
          if let description = current?.preview.description {
            Text(description)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
          HStack(spacing: 5) {
            WorkspaceInspectorSiteIcon(url: link.url, client: client)
              .frame(width: 12, height: 12)
            Text(current?.preview.siteName ?? WorkspaceInspectorLinksView.host(link.url))
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        if let image = current?.image {
          Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
      }
      .contentShape(Rectangle())
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
