import CodevisorCore
import CodevisorUI
import SwiftUI

/// The navigator's Source Control tab: the repository's changed files in an
/// editor's groups (merge conflicts, staged, then everything else), with
/// staging and discarding on each row and group. Selecting a file previews
/// its diff; double-clicking or Return keeps the tab.
struct SourceControlView: View {
  @Bindable var model: SourceControlModel
  /// Whether the machine can list and stage changes at all.
  let isSupported: Bool
  /// The row for the diff facing the user, so the list can highlight it.
  let activeChangeId: String?
  let onOpenDiff: (SourceControlChange, _ preview: Bool) -> Void
  let onOpenFile: (String, _ preview: Bool) -> Void
  @State private var pendingDiscard: [SourceControlChange]?

  var body: some View {
    List(selection: $model.selection) {
      if !model.merge.isEmpty {
        Section {
          rows(model.merge)
        } header: {
          SourceControlSectionHeader(title: "Merge Changes", count: model.merge.count) {
            actionButton("Stage All Merge Changes", systemImage: "plus") { await model.stage(model.merge) }
          }
        }
      }
      if !model.staged.isEmpty {
        Section {
          rows(model.staged)
        } header: {
          SourceControlSectionHeader(title: "Staged Changes", count: model.staged.count) {
            actionButton("Unstage All Changes", systemImage: "minus") { await model.unstageAll() }
          }
        }
      }
      if !model.changes.isEmpty {
        Section {
          rows(model.changes)
        } header: {
          SourceControlSectionHeader(title: "Changes", count: model.changes.count) {
            actionButton("Discard All Changes", systemImage: "arrow.uturn.backward") {
              pendingDiscard = model.changes
            }
            actionButton("Stage All Changes", systemImage: "plus") { await model.stage(model.changes) }
          }
        }
      }
    }
    .navigatorListStyle()
    .disabled(model.isChanging)
    .contextMenu(forSelectionType: String.self) { ids in
      if ids.count == 1, let id = ids.first, let change = model.change(id: id) {
        contextMenu(for: change)
      }
    } primaryAction: { ids in
      guard ids.count == 1, let id = ids.first, let change = model.change(id: id) else { return }
      open(change, preview: false)
    }
    .onChange(of: model.selection) { _, id in
      // Following the active diff is not a request to open it.
      guard let id, id != activeChangeId, let change = model.change(id: id) else { return }
      open(change, preview: true)
    }
    .onChange(of: activeChangeId, initial: true) { _, id in followActiveChange(id) }
    .onChange(of: model.status) { _, _ in
      if model.selection.flatMap(model.change(id:)) == nil { followActiveChange(activeChangeId) }
    }
    .overlay { placeholder }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let error = model.error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .alert(
      discardTitle,
      isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }),
      presenting: pendingDiscard
    ) { changes in
      Button(changes.allSatisfy { $0.code == .untracked } ? "Delete" : "Discard Changes", role: .destructive) {
        Task { await model.discard(changes) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("This can't be undone.")
    }
  }

  @ViewBuilder
  private func rows(_ changes: [SourceControlChange]) -> some View {
    ForEach(changes) { change in
      SourceControlRow(change: change) {
        if change.group != .changes {
          // Staged changes leave the index; conflicts are marked resolved.
          if change.isStaged {
            actionButton("Unstage Changes", systemImage: "minus") { await model.unstage([change]) }
          } else {
            actionButton("Stage Changes", systemImage: "plus") { await model.stage([change]) }
          }
        } else {
          if change.code != .deleted {
            actionButton("Open File", systemImage: "doc") { onOpenFile(model.absolutePath(change), false) }
          }
          actionButton("Discard Changes", systemImage: "arrow.uturn.backward") { pendingDiscard = [change] }
          actionButton("Stage Changes", systemImage: "plus") { await model.stage([change]) }
        }
      }
      .navigatorRow()
      .tag(change.id)
    }
  }

  @ViewBuilder
  private func contextMenu(for change: SourceControlChange) -> some View {
    if change.group != .merge {
      Button("Open Changes") { onOpenDiff(change, false) }
    }
    if change.code != .deleted {
      Button("Open File") { onOpenFile(model.absolutePath(change), false) }
    }
    Divider()
    if change.isStaged {
      Button("Unstage Changes") { Task { await model.unstage([change]) } }
    } else {
      Button("Stage Changes") { Task { await model.stage([change]) } }
    }
    if change.group == .changes {
      Button("Discard Changes…", role: .destructive) { pendingDiscard = [change] }
    }
    Divider()
    Button("Copy Path") { NavigatorList.copy(model.absolutePath(change)) }
    Button("Copy Relative Path") { NavigatorList.copy(change.path) }
  }

  private func actionButton(
    _ title: String, systemImage: String, action: @escaping () async -> Void
  ) -> some View {
    Button {
      Task { await action() }
    } label: {
      Image(systemName: systemImage)
        .font(.system(size: Typography.IconSize.chrome, weight: .medium))
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .help(title)
    .accessibilityLabel(title)
  }

  /// A conflict has no diff against one side to show: open the file to
  /// resolve it.
  private func open(_ change: SourceControlChange, preview: Bool) {
    if change.group == .merge {
      onOpenFile(model.absolutePath(change), preview)
    } else {
      onOpenDiff(change, preview)
    }
  }

  private func followActiveChange(_ id: String?) {
    let target = id.flatMap { model.change(id: $0) == nil ? nil : $0 }
    if model.selection != target { model.selection = target }
  }

  private var discardTitle: String {
    guard let changes = pendingDiscard else { return "" }
    if changes.count == 1, let change = changes.first {
      return change.code == .untracked
        ? "Delete \(change.name)?" : "Discard changes in \(change.name)?"
    }
    return "Discard changes in \(changes.count) files?"
  }

  @ViewBuilder
  private var placeholder: some View {
    if !isSupported {
      ContentUnavailableView(
        "Source Control Unavailable", systemImage: "arrow.trianglehead.branch",
        description: Text("Update Codevisor on this machine to see and stage its changes here."))
    } else if model.isNotRepository {
      ContentUnavailableView(
        "Not a Git Repository", systemImage: "folder.badge.questionmark",
        description: Text("This workspace's folder isn't in a Git repository."))
    } else if !model.hasLoaded {
      if model.error == nil { ProgressView().controlSize(.small) }
    } else if model.count == 0 {
      ContentUnavailableView(
        "No Changes", systemImage: "checkmark.circle",
        description: Text(model.status?.branch.map { "\($0) is up to date with its last commit." } ?? ""))
    }
  }
}

/// A group's title and count, with its bulk actions on hover.
private struct SourceControlSectionHeader<Actions: View>: View {
  let title: String
  let count: Int
  @ViewBuilder let actions: () -> Actions
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 6) {
      Text(title)
      Spacer(minLength: 4)
      if isHovered {
        HStack(spacing: 2) { actions() }
      }
      Text("\(count)")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(.quaternary))
    }
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
  }
}

/// One changed file: its icon and name, the folder it's in, its actions on
/// hover, and the editor's status letter.
private struct SourceControlRow<Actions: View>: View {
  let change: SourceControlChange
  @ViewBuilder let actions: () -> Actions
  @Environment(\.backgroundProminence) private var prominence
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 4) {
      FileIcon(path: change.path, size: NavigatorList.iconSize)
      Text(change.name)
        .strikethrough(change.code == .deleted)
        .lineLimit(1)
        .layoutPriority(1)
      if !change.directory.isEmpty {
        Text(change.directory)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.head)
      }
      Spacer(minLength: 4)
      if isHovered {
        HStack(spacing: 2) { actions() }
      }
      Text(change.code.letter)
        .font(.system(.callout, design: .monospaced).weight(.semibold))
        // White on a selected row, like its icon.
        .foregroundStyle(prominence == .increased ? .white : change.code.color)
        .frame(width: 14)
        .help(change.code.title)
    }
    .frame(height: NavigatorList.rowHeight)
    .padding(.leading, 4)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(change.name), \(change.code.title)")
  }
}

extension ServerGitChangeCode {
  /// The editor's one-letter badge.
  var letter: String {
    switch self {
    case .added: "A"
    case .modified: "M"
    case .deleted: "D"
    case .renamed: "R"
    case .typeChanged: "T"
    case .untracked: "U"
    case .conflicted: "!"
    }
  }

  var title: String {
    switch self {
    case .added: "Added"
    case .modified: "Modified"
    case .deleted: "Deleted"
    case .renamed: "Renamed"
    case .typeChanged: "Type Changed"
    case .untracked: "Untracked"
    case .conflicted: "Conflict"
    }
  }

  var color: Color {
    switch self {
    case .added, .untracked: .green
    case .modified, .typeChanged: .orange
    case .deleted, .conflicted: .red
    case .renamed: .blue
    }
  }
}
