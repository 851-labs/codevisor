import CodevisorCore
import SwiftUI

/// The Review pane: every changed file in the workspace, stacked with
/// pinned file headers and folded context. What it compares lives in the
/// window toolbar (`ReviewPaneToolbar`).
public struct ReviewPaneView: View {
  @Bindable private var model: ReviewPaneModel
  @Environment(\.theme) private var theme
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Each unchanged poll costs the server roughly a `git status`.
  static let pollInterval: Duration = .seconds(2)

  public init(model: ReviewPaneModel) {
    self.model = model
  }

  public var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      // Painted explicitly: pinned headers back their corners with it.
      .background(ReviewSurface(theme: theme).page)
      // Agents and editors change files underneath the review, so it
      // keeps itself current while on screen and the app is active. The
      // task ends when the pane leaves the screen or the app goes inactive,
      // and polling resumes (checking at once) when it comes back.
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

  /// One motion for every fold and unfold, whether from the disclosure or
  /// from marking a file viewed: a short spring without bounce, per the
  /// HIG's guidance for quick, purposeful transitions. Reduce Motion makes
  /// the change instant.
  private var disclosureAnimation: Animation? {
    reduceMotion ? nil : .smooth(duration: 0.25)
  }

  private var fileList: some View {
    ScrollView {
      // Files run edge to edge, back to back: hairlines separate them.
      LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
        ForEach(model.files) { diff in
          let isCollapsed = model.collapsedFiles.contains(diff.id)
          Section {
            if !isCollapsed {
              ReviewFileBody(diff: diff)
                .reviewCardBody(theme: theme)
                // The diff dissolves while the files below slide, like a
                // native disclosure group; nothing stretches or slides in.
                .transition(.opacity)
            }
          } header: {
            ReviewFileHeader(
              diff: diff, isCollapsed: isCollapsed, isViewed: model.isViewed(diff),
              toggle: { withAnimation(disclosureAnimation) { model.toggleCollapsed(diff) } },
              toggleViewed: { withAnimation(disclosureAnimation) { model.toggleViewed(diff) } }
            )
            .reviewCardHeader(isCollapsed: isCollapsed, theme: theme)
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
    // Only the dimming animates; the new diff itself swaps in at once.
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
