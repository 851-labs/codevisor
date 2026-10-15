import AppKit
import CodevisorClient
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorOpenTab: Identifiable {
  let id: UUID
  let url: URL
  let title: String
  let favicon: NSImage?
}

struct WorkspaceInspectorLinksView: View {
  let openTabs: [WorkspaceInspectorOpenTab]
  let model: WorkspaceInspectorMediaModel
  let client: any CodevisorServerClienting
  let onOpen: (WorkspaceInspectorView.Destination) -> Void
  let onRetry: () -> Void

  @Environment(\.theme) private var theme

  private var chatLinks: [ServerWorkspaceLink] {
    let open = Set(openTabs.map { Self.matchKey($0.url) })
    return model.links.filter { !open.contains(Self.matchKey($0.url)) }
  }

  var body: some View {
    if openTabs.isEmpty && model.links.isEmpty {
      WorkspaceInspectorMediaPlaceholder(
        phase: model.linksPhase, emptyTitle: "No Links", systemImage: "link",
        emptyDescription: "Links mentioned in this workspace's chats and its open browser tabs appear here.",
        onRetry: onRetry
      )
    } else {
      Form {
        if !openTabs.isEmpty {
          Section("Open Tabs") {
            ForEach(openTabs) { tab in
              row(title: tab.title, subtitle: Self.host(tab.url), url: tab.url, destination: .browserPane(tab.id)) {
                if let favicon = tab.favicon {
                  Image(nsImage: favicon).resizable().scaledToFit()
                } else {
                  WorkspaceInspectorSiteIcon(url: tab.url, client: client)
                }
              }
            }
          }
        }
        Section("From Chats") {
          let links = chatLinks
          ForEach(links) { link in
            row(
              title: link.title ?? Self.host(link.url),
              subtitle: link.title == nil ? Self.location(link.url) : Self.host(link.url),
              url: link.url, destination: .link(link.url)
            ) {
              WorkspaceInspectorSiteIcon(url: link.url, client: client)
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
          } else if links.isEmpty {
            Text(model.linksPhase == .loading ? "Loading…" : "No links in chats yet")
              .foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
    }
  }

  private func row(
    title: String, subtitle: String, url: URL, destination: WorkspaceInspectorView.Destination,
    @ViewBuilder icon: () -> some View
  ) -> some View {
    Button {
      onOpen(destination)
    } label: {
      HStack(spacing: 8) {
        icon()
          .frame(width: 16, height: 16)
        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .lineLimit(1)
            .truncationMode(.tail)
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(url.absoluteString)
    .contextMenu {
      Button("Copy Link") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
      }
      Button("Open in Default Browser") {
        NSWorkspace.shared.open(url)
      }
    }
  }

  private static func host(_ url: URL) -> String {
    guard let host = url.host() else { return BrowserLocation.display(url) }
    return url.port.map { "\(host):\($0)" } ?? host
  }

  private static func location(_ url: URL) -> String {
    let path = url.path(percentEncoded: false)
    guard path.count > 1 else { return host(url) }
    return host(url) + (path.hasSuffix("/") ? String(path.dropLast()) : path)
  }

  private static func matchKey(_ url: URL) -> String {
    (BrowserLocation.canonicalURL(url) ?? url).absoluteString
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
