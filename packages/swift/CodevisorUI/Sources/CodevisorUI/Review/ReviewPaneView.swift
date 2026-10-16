import CodevisorCore
import SwiftUI

public struct ReviewPaneView: View {
  @Bindable private var model: ReviewPaneModel
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static let pollInterval: Duration = .seconds(2)

  public init(model: ReviewPaneModel) {
    self.model = model
  }

  public var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(ReviewSurface.page)
      #if !canImport(AppKit)
        .sheet(isPresented: $model.showsBranchPicker) {
          ReviewBranchSheet(model: model)
        }
      #endif
      .task(id: scenePhase == .active) {
        model.loadIfNeeded()
        guard scenePhase == .active else { return }
        while !Task.isCancelled {
          model.poll()
          try? await Task.sleep(for: Self.pollInterval)
        }
      }
  }

  @ViewBuilder
  private var content: some View {
    if let failure = model.failure {
      failureView(failure)
    } else if !model.hasLoaded {
      ProgressView()
        .controlSize(.regular)
        .accessibilityLabel("Loading changes")
    } else if model.files.isEmpty {
      ContentUnavailableView {
        Label(model.mode.emptyTitle, systemImage: "checkmark.circle")
      } description: {
        Text(model.mode.summary(base: model.baseDisplayName))
      } actions: {
        if model.mode == .branch { chooseBranchButton }
      }
    } else {
      fileList
    }
  }

  private var disclosureAnimation: Animation? {
    reduceMotion ? nil : .smooth(duration: 0.25)
  }

  private var fileList: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
        ForEach(model.files) { diff in
          let isCollapsed = model.collapsedFiles.contains(diff.id)
          Section {
            if !isCollapsed {
              ReviewFileBody(diff: diff)
                .reviewCardBody()
                .transition(.opacity)
            }
          } header: {
            ReviewFileHeader(
              diff: diff, isCollapsed: isCollapsed, isViewed: model.isViewed(diff),
              toggle: { withAnimation(disclosureAnimation) { model.toggleCollapsed(diff) } },
              toggleViewed: { withAnimation(disclosureAnimation) { model.toggleViewed(diff) } }
            )
            .reviewCardHeader(isCollapsed: isCollapsed)
          }
        }
        if model.truncated {
          Text("Showing the first \(model.files.count) files.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
      }
    }
    .animation(.default) { $0.opacity(model.isStale ? 0.5 : 1) }
  }

  @ViewBuilder
  private func failureView(_ failure: ReviewFailure) -> some View {
    switch failure.kind {
    case .notRepository:
      ContentUnavailableView(
        "Not a Git Repository", systemImage: "folder.badge.questionmark",
        description: Text("Review shows changes in Git repositories, and this workspace's folder isn't one."))
    case .noTurnYet:
      ContentUnavailableView {
        Label("No Agent Turns Yet", systemImage: ServerGitDiffMode.lastTurn.systemImage)
      } description: {
        Text("Codevisor records the folder each time a chat turn starts. Send a prompt, then check back.")
      } actions: {
        Button("Show Uncommitted Changes") { model.setMode(.uncommitted) }
      }
    case .unknownBase:
      ContentUnavailableView {
        Label("Branch Not Found", systemImage: ServerGitDiffMode.branch.systemImage)
      } description: {
        Text(failure.message)
      } actions: {
        chooseBranchButton
      }
    case .unmergedIndex, .other:
      ContentUnavailableView {
        Label("Couldn't Load Changes", systemImage: "exclamationmark.triangle")
      } description: {
        Text(failure.message)
      } actions: {
        Button("Try Again") { model.reload() }
      }
    }
  }

  @ViewBuilder
  private var chooseBranchButton: some View {
    #if canImport(AppKit)
      Menu("Choose Branch") {
        ReviewBranchPicker(model: model)
      }
      .fixedSize()
      .task { await model.loadRefs() }
    #else
      Button("Choose Branch…") { model.showsBranchPicker = true }
    #endif
  }
}
