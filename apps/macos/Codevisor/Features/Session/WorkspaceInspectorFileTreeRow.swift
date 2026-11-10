import CodevisorClient
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorFileTreeRow: View {
  struct Actions {
    let click: () -> Void
    let doubleClick: () -> Void
    let download: () -> Void
    let copy: () -> Void
    let copyPath: () -> Void
    let rename: (() -> Void)?
    let delete: () -> Void
    let deleteTitle: String
    let commitRename: (String, Bool) -> Void
    let cancelRename: () -> Void
  }

  let row: WorkspaceInspectorFileTreeModel.Row
  let isExpanded: Bool
  let isLoading: Bool
  let selection: WorkspaceInspectorFileSelectionBackground.Look?
  let isDropTarget: Bool
  let isRenaming: Bool
  let actions: Actions

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.controlActiveState) private var controlActiveState

  static let height: CGFloat = 22
  static let spacing: CGFloat = 1
  private static let indent: CGFloat = 14

  private var entry: ServerFileEntry { row.entry }

  private var shownSelection: WorkspaceInspectorFileSelectionBackground.Look? {
    guard let selection else { return nil }
    return WorkspaceInspectorFileSelectionBackground.Look(
      isEmphasized: selection.isEmphasized && controlActiveState == .key,
      joinsPrevious: selection.joinsPrevious,
      joinsNext: selection.joinsNext
    )
  }

  private var isProminent: Bool {
    shownSelection?.isEmphasized == true
  }

  private var expansionValue: LocalizedStringKey {
    guard entry.isDirectory else { return "" }
    return isExpanded ? "Expanded" : "Collapsed"
  }

  var body: some View {
    HStack(spacing: 0) {
      disclosure
      FileIcon(path: entry.path, isDirectory: entry.isDirectory, size: 15)
      name.padding(.leading, 6)
      Spacer(minLength: 0)
    }
    .foregroundStyle(isProminent ? Color.white : Color.primary)
    .padding(.leading, CGFloat(row.depth) * Self.indent + 4)
    .padding(.trailing, 6)
    .frame(height: Self.height)
    .contentShape(Rectangle())
    .background {
      if let shownSelection {
        WorkspaceInspectorFileSelectionBackground(look: shownSelection, gap: Self.spacing)
      }
    }
    .sidebarRowHover(isEnabled: selection == nil)
    .background {
      if isDropTarget {
        RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.2))
      }
    }
    .onTapGesture(perform: tap)
    .help(entry.path)
    .contextMenu { menu }
    .accessibilityElement(children: isRenaming ? .contain : .ignore)
    .accessibilityLabel(entry.name)
    .accessibilityValue(expansionValue)
    .accessibilityAddTraits(selection == nil ? .isButton : [.isButton, .isSelected])
    .accessibilityHint(entry.isDirectory ? "" : "Opens the file")
    .accessibilityAction { actions.click() }
    .accessibilityAction(named: "Rename") { actions.rename?() }
  }

  private var disclosure: some View {
    ZStack {
      if isLoading {
        ProgressView().controlSize(.mini)
      } else if entry.isDirectory {
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .scaleEffect(0.95)
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .animation(Motion.listReflow(reduceMotion: reduceMotion), value: isExpanded)
      }
    }
    .frame(width: 10, height: 10)
    .padding(.trailing, 3.5)
  }

  @ViewBuilder
  private var name: some View {
    if isRenaming {
      WorkspaceInspectorFileRenameField(
        original: entry.name, isDirectory: entry.isDirectory, onCommit: actions.commitRename,
        onCancel: actions.cancelRename
      )
      .frame(height: Self.height - 2)
    } else {
      Text(entry.name)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  @ViewBuilder
  private var menu: some View {
    Button("Download", action: actions.download)
    Button("Copy", action: actions.copy)
    Button("Copy Path", action: actions.copyPath)
    Divider()
    Button("Rename") { actions.rename?() }
      .disabled(actions.rename == nil)
    Button(actions.deleteTitle, action: actions.delete)
  }

  private func tap() {
    guard !isRenaming else { return }

    let isDoubleClick = NSApp.currentEvent.map { $0.type == .leftMouseUp && $0.clickCount > 1 } ?? false
    if isDoubleClick, !entry.isDirectory {
      actions.doubleClick()
    } else {
      actions.click()
    }
  }
}
