import ACPKit
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
  let machineSymbol: String?
  let showsDebugSection: Bool
  let showsBotTranscript: Bool
  let harnessChat: ChatSession?
  let agents: [WorkspaceInspectorAgent]
  let store: SessionStore
  let usage: WorkspaceInspectorUsageModel
  let tabs: [WorkspaceInspectorTab]
  @Binding var tab: WorkspaceInspectorTab
  let media: WorkspaceInspectorMediaModel
  let fileTree: WorkspaceInspectorFileTreeModel
  let activeFilePath: String?
  let chatUsage: SessionUsage?
  let activity: Date?
  let client: any CodevisorServerClienting
  let desktop: MachineDesktopSession?
  let onOpenDesktop: () -> Void
  let onReload: () -> Void
  let onOpen: (Destination) -> Void

  private struct TabViewport: Equatable {
    var offset: CGFloat = 0
    var width: CGFloat = 0
    var contentWidth: CGFloat = 0

    var overflowsLeading: Bool { offset > 1 }
    var overflowsTrailing: Bool { offset + width < contentWidth - 1 }
  }

  private static let tabOverflowInset: CGFloat = 40

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var tabBarWidth: CGFloat = 0
  @State private var tabScroll = ScrollPosition(edge: .leading)
  @State private var tabViewport = TabViewport()
  @State private var tabFrames: [WorkspaceInspectorTab: CGRect] = [:]
  @State private var visited: Set<WorkspaceInspectorTab> = []
  @State private var chatContexts: [UUID: ServerSessionContext] = [:]
  @State private var lastLoadedChatId: UUID?
  @ClientPreference("workspace.inspectorCollapsedSections", default: []) private var collapsedSections: [String]

  var body: some View {
    ZStack {
      ForEach(tabs.filter { $0 == tab || visited.contains($0) }) { candidate in
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
        WorkspaceInspectorTabBar(selection: $tab, tabs: tabs, harnessId: harnessChat?.harnessId) { tabFrames = $0 }
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
      .mask {
        HStack(spacing: 0) {
          tabOverflowFade(.leading, isActive: tabViewport.overflowsLeading)
          Rectangle()
          tabOverflowFade(.trailing, isActive: tabViewport.overflowsTrailing)
        }
      }
      .overlay(alignment: .leading) {
        tabOverflowChevron(.leading, isActive: tabViewport.overflowsLeading)
      }
      .overlay(alignment: .trailing) {
        tabOverflowChevron(.trailing, isActive: tabViewport.overflowsTrailing)
      }
      .animation(.easeOut(duration: 0.2), value: [tabViewport.overflowsLeading, tabViewport.overflowsTrailing])
    }
  }

  private func tabOverflowFade(_ edge: HorizontalEdge, isActive: Bool) -> some View {
    ZStack {
      Rectangle()
        .opacity(isActive ? 0 : 1)
      LinearGradient(
        stops: [
          .init(color: .black.opacity(0.06), location: 0), .init(color: .black.opacity(0.14), location: 0.5),
          .init(color: .black, location: 1),
        ],
        startPoint: edge == .leading ? .leading : .trailing,
        endPoint: edge == .leading ? .trailing : .leading
      )
      .opacity(isActive ? 1 : 0)
    }
    .frame(width: Self.tabOverflowInset)
  }

  private func tabOverflowChevron(_ edge: HorizontalEdge, isActive: Bool) -> some View {
    Button {
      scrollTabs(toward: edge)
    } label: {
      Image(systemName: edge == .leading ? "chevron.left" : "chevron.right")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.primary)
        .frame(width: 20, height: 26)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 6)
    .opacity(isActive ? 1 : 0)
    .allowsHitTesting(isActive)
    .accessibilityHidden(!isActive)
    .accessibilityLabel(edge == .leading ? "Scroll Tabs Left" : "Scroll Tabs Right")
  }

  private func scrollTabs(toward edge: HorizontalEdge) {
    let page = max(tabViewport.width - 2 * Self.tabOverflowInset, 0)
    scrollTabs(to: tabViewport.offset + (edge == .leading ? -page : page), animated: true)
  }

  private func revealTab(_ tab: WorkspaceInspectorTab, animated: Bool) {
    guard let frame = tabFrames[tab], tabViewport.width > 0 else { return }
    let margin = WorkspaceInspectorTabBar.scrollMargin
    let leading = frame.minX + margin - Self.tabOverflowInset
    let trailing = frame.maxX + margin + Self.tabOverflowInset
    if leading < tabViewport.offset {
      scrollTabs(to: leading, animated: animated)
    } else if trailing > tabViewport.offset + tabViewport.width {
      scrollTabs(to: trailing - tabViewport.width, animated: animated)
    }
  }

  private func scrollTabs(to offset: CGFloat, animated: Bool) {
    let maxOffset = max(tabViewport.contentWidth - tabViewport.width, 0)
    let snap = min(Self.tabOverflowInset, maxOffset / 2)
    let target = offset < snap ? 0 : offset > maxOffset - snap ? maxOffset : offset
    withAnimation(animated && !reduceMotion ? .smooth(duration: 0.28) : nil) {
      tabScroll.scrollTo(x: target)
    }
  }

  private var botTranscriptRow: some View {
    row(.botTranscript) {
      Label {
        HStack {
          Text("Show Full Transcript")
          Spacer(minLength: 8)
          Image(systemName: "arrow.up.forward.square")
            .foregroundStyle(.secondary)
        }
      } icon: {
        Image(systemName: "text.page")
          .foregroundStyle(.secondary)
          .frame(width: 20)
      }
    }
    .help("Show everything the bot did, including its tool calls and the messages it received")
    .accessibilityIdentifier("bot.showFullTranscript")
  }

  @ViewBuilder
  private func content(for tab: WorkspaceInspectorTab) -> some View {
    switch tab {
    case .info: info
    case .harness: harness
    case .machine:
      WorkspaceInspectorMachineView(
        serverId: workspace.serverId, isActive: self.tab == .machine, client: client, desktop: desktop,
        desktopExpansion: expansion("Desktop"),
        statsExpansion: expansion("Stats"), onOpenDesktop: onOpenDesktop)
    case .media: WorkspaceInspectorMediaView(model: media, onRetry: onReload)
    case .links:
      WorkspaceInspectorLinksView(model: media, client: client, onOpen: onOpen, onRetry: onReload)
    case .files: WorkspaceInspectorFileTreeView(model: fileTree, activeFilePath: activeFilePath, onOpen: onOpen)
    }
  }

  private var info: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        if showsDebugSection && showsBotTranscript {
          WorkspaceInspectorCard(title: "Debug", isExpanded: expansion("Debug")) {
            botTranscriptRow
          }
        }

        if let pullRequest {
          WorkspaceInspectorCard(title: "Pull Request", isExpanded: expansion("Pull Request")) {
            row(.pullRequest(pullRequest.url)) {
              Label {
                Text("PR #\(pullRequest.number): \(pullRequest.title)")
                  .lineLimit(1)
                  .truncationMode(.tail)
              } icon: {
                pullRequest.statusSymbol.image
                  .foregroundStyle(pullRequest.statusColor)
              }
            }
          }
        }

        WorkspaceInspectorCard(title: "Details", isExpanded: expansion("Details")) {
          detail("Project", systemImage: "folder", value: project.name)
          if let branch {
            detail("Branch", systemImage: "arrow.triangle.branch", value: branch)
          }
          if let worktree = workspace.worktreeName {
            detail("Worktree", systemImage: "tree", value: worktree)
          }
          if let machineName {
            detail("Machine", systemImage: machineSymbol ?? MachineIcon.fallback.systemImage, value: machineName)
          }
        }

        if !agents.isEmpty {
          WorkspaceInspectorAgentsSection(agents: agents, store: store, isExpanded: expansion("Agents"))
        }
      }
      .padding(.vertical, 10)
    }
  }

  private var harness: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        if let harnessChat, let limits = usage.limits(for: harnessChat) {
          WorkspaceInspectorUsageSection(limits: limits, isExpanded: expansion("Usage"))
        }

        if let harnessChat {
          WorkspaceInspectorContextSection(
            context: chatContexts[harnessChat.id] ?? lastLoadedChatId.flatMap { chatContexts[$0] }, usage: chatUsage,
            isExpanded: expansion("Context"))
        }
      }
      .padding(.vertical, 10)
    }
    .task(
      id: harnessChat.map {
        WorkspaceInspectorContextSection.LoadKey(sessionId: $0.id, usage: chatUsage, activity: activity)
      }
    ) {
      guard let harnessChat else { return }
      let context = try? await client.sessionContext(id: harnessChat.id)
      guard !Task.isCancelled else { return }
      if let context { chatContexts[harnessChat.id] = context }
      lastLoadedChatId = harnessChat.id
    }
  }

  private func detail(_ title: String, systemImage: String, value: String) -> some View {
    Label {
      Text(value)
        .textSelection(.enabled)
    } icon: {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 20)
    }
    .help(title)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(value)
  }

  private func expansion(_ section: String) -> Binding<Bool> {
    Binding(
      get: { !collapsedSections.contains(section) },
      set: { expanded in
        withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) {
          collapsedSections = collapsedSections.filter { $0 != section } + (expanded ? [] : [section])
        }
      }
    )
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
