import CodevisorClient
import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorView: View {
  enum Destination: Equatable {
    case pullRequest(URL), link(URL), file(String), previewFile(String), botTranscript
  }

  let workspace: Workspace
  let project: Project
  let branch: String?
  let pullRequest: ServerGitPullRequest?
  let machineName: String?
  let showsBotTranscript: Bool
  @Binding var tab: WorkspaceInspectorTab
  let media: WorkspaceInspectorMediaModel
  let fileTree: WorkspaceInspectorFileTreeModel
  let activeFilePath: String?
  let client: any CodevisorServerClienting
  let onReload: () -> Void
  let onOpen: (Destination) -> Void

  private struct TabViewport: Equatable {
    var offset: CGFloat = 0
    var width: CGFloat = 0
    var contentWidth: CGFloat = 0
  }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var tabBarWidth: CGFloat = 0
  @State private var tabScroll = ScrollPosition(edge: .leading)
  @State private var tabViewport = TabViewport()
  @State private var tabFrames: [WorkspaceInspectorTab: CGRect] = [:]
  @State private var visited: Set<WorkspaceInspectorTab> = []

  var body: some View {
    ZStack {
      ForEach(WorkspaceInspectorTab.allCases.filter { $0 == tab || visited.contains($0) }) { candidate in
        content(for: candidate)
          .opacity(candidate == tab ? 1 : 0)
          .allowsHitTesting(candidate == tab)
          .disabled(candidate != tab)
          .accessibilityHidden(candidate != tab)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .scrollEdgeEffectStyle(.soft, for: .top)
    .onChange(of: tab, initial: true) { _, selected in visited.insert(selected) }
    .safeAreaBar(edge: .top, spacing: 0) {
      ScrollView(.horizontal, showsIndicators: false) {
        WorkspaceInspectorTabBar(selection: $tab) { tabFrames = $0 }
          .padding(.horizontal, WorkspaceInspectorTabBar.scrollMargin)
          .padding(.vertical, 8)
          .frame(minWidth: tabBarWidth)
      }
      .scrollPosition($tabScroll)
      .scrollBounceBehavior(.always, axes: .horizontal)
      .onScrollGeometryChange(for: TabViewport.self) { geometry in
        TabViewport(
          offset: geometry.contentOffset.x, width: geometry.containerSize.width,
          contentWidth: geometry.contentSize.width)
      } action: { _, viewport in
        tabViewport = viewport
      }
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: { width in
        tabBarWidth = width
        Task { revealTab(tab, animated: false) }
      }
      .onChange(of: tab) { _, selected in revealTab(selected, animated: true) }
    }
  }

  private func revealTab(_ tab: WorkspaceInspectorTab, animated: Bool) {
    guard let frame = tabFrames[tab], tabViewport.width > 0 else { return }
    let leading = frame.minX
    let trailing = frame.maxX + 2 * WorkspaceInspectorTabBar.scrollMargin
    let target: CGFloat
    if leading < tabViewport.offset {
      target = leading
    } else if trailing > tabViewport.offset + tabViewport.width {
      target = trailing - tabViewport.width
    } else {
      return
    }
    let clamped = min(max(target, 0), max(tabViewport.contentWidth - tabViewport.width, 0))
    withAnimation(animated && !reduceMotion ? .smooth(duration: 0.28) : nil) {
      tabScroll.scrollTo(x: clamped)
    }
  }

  @ViewBuilder
  private func content(for tab: WorkspaceInspectorTab) -> some View {
    switch tab {
    case .info: info
    case .photos: WorkspaceInspectorPhotosView(model: media, onRetry: onReload)
    case .links:
      WorkspaceInspectorLinksView(model: media, client: client, onOpen: onOpen, onRetry: onReload)
    case .sourceControl: WorkspaceInspectorSourceControlView(model: media, onOpen: onOpen, onRetry: onReload)
    case .files: WorkspaceInspectorFileTreeView(model: fileTree, activeFilePath: activeFilePath, onOpen: onOpen)
    }
  }

  private var info: some View {
    Form {
      if let pullRequest {
        Section("Pull Request") {
          row(.pullRequest(pullRequest.url)) {
            Label {
              Text("PR #\(pullRequest.number): \(pullRequest.title)")
                .lineLimit(1)
                .truncationMode(.tail)
            } icon: {
              pullRequest.statusImage
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .foregroundStyle(pullRequest.statusColor)
            }
          }
        }
      }

      Section {
        LabeledContent("Project", value: project.name)
        if let branch {
          LabeledContent("Branch", value: branch)
        }
        if let worktree = workspace.worktreeName {
          LabeledContent("Worktree", value: worktree)
        }
        if let machineName {
          LabeledContent("Machine", value: machineName)
        }
        LabeledContent("Created", value: workspace.createdAt, format: .relative(presentation: .named))
      } header: {
        Text("Details")
      } footer: {
        if showsBotTranscript {
          Button("Show Full Transcript") { onOpen(.botTranscript) }
            .foregroundStyle(.primary)
            .help("Show everything the bot did, including its tool calls and the messages it received")
            .accessibilityIdentifier("bot.showFullTranscript")
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
      }
    }
    .formStyle(.grouped)
  }

  private func row(_ destination: Destination, @ViewBuilder label: () -> some View) -> some View {
    Button {
      onOpen(destination)
    } label: {
      label()
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
