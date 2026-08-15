import CodevisorCore
import SwiftUI

/// One workspace row, either top-level or nested beneath its project.
/// Nested rows are disclosure-only; top-level workspace rows retain their
/// primary-chat activation behavior.
struct SidebarWorkspaceRow: View {
    let item: SidebarWorkspaceListItem
    let store: SessionStore?
    var isNested = false
    var isExpanded = false
    var onToggle: (() -> Void)? = nil
    let isSelected: Bool
    let isReordering: Bool
    let titleFont: Font
    let hierarchyIndent: CGFloat
    let onActivateSession: (ChatSession) -> Void
    let onArchive: () -> Void
    let onRename: () -> Void
    let onChangeIcon: () -> Void

    var body: some View {
        HoverableRow(
            isSelected: isSelected,
            isHoverEnabled: !isReordering,
            isHoverForced: false
        ) { isHovered in
            HStack(spacing: 7) {
                if let onToggle {
                    Button(action: onToggle) {
                        HStack(spacing: 7) {
                            ZStack {
                                Image(systemName: FilledSymbol.preferred("square.grid.2x2"))
                                    .foregroundStyle(.secondary)
                                    .opacity(isHovered ? 0 : 1)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                    .opacity(isHovered ? 1 : 0)
                            }
                            .frame(width: 18)
                            Text(title)
                                .font(titleFont)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(isExpanded ? "Collapse workspace" : "Expand workspace")
                    .accessibilityLabel(
                        isExpanded
                            ? "Collapse \(item.workspace.name)"
                            : "Expand \(item.workspace.name)"
                    )
                    if let session = item.primarySession, isHovered {
                        SidebarSessionStatus(
                            session: session,
                            store: store,
                            isHovered: true,
                            onArchive: onArchive
                        )
                    }
                } else {
                    Image(systemName: symbol)
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(titleFont)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if onToggle == nil, let session = item.primarySession {
                    SidebarSessionStatus(
                        session: session,
                        store: store,
                        isHovered: isHovered,
                        onArchive: onArchive
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.leading, isNested ? hierarchyIndent : 0)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .foregroundStyle(isSelected ? Color.primary : .secondary)
            .gesture(
                activationGesture,
                including: onToggle == nil ? .all : .none
            )
            .onTapGesture {
                guard onToggle == nil else { return }
                guard let session = item.primarySession else { return }
                onActivateSession(session)
            }
        }
        .contextMenu {
            Button {
                onRename()
            } label: {
                Label("Rename", systemImage: "pencil")
                    .labelStyle(.titleAndIcon)
            }
            Button {
                onChangeIcon()
            } label: {
                Label("Change Icon", systemImage: "app.grid")
                    .labelStyle(.titleAndIcon)
            }
            Button {
                onArchive()
            } label: {
                Label("Archive", systemImage: "archivebox")
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    /// Top-level workspace rows route through their primary chat. Match chat
    /// rows by doing that work on pointer-down; nested workspace rows remain
    /// disclosure-only and disable this gesture at the call site.
    private var activationGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard let session = item.primarySession else { return }
                onActivateSession(session)
            }
    }

    /// The workspace's own icon; a workspace born before icons existed
    /// falls back to its project's, then to a generic glyph.
    private var symbol: String {
        if let symbol = item.workspace.symbolName {
            return FilledSymbol.preferred(symbol)
        }
        if let project = item.project {
            return FilledSymbol.preferred(project.symbolName)
        }
        return "square.grid.2x2"
    }

    private var title: String {
        guard !isNested, let project = item.project else {
            return item.workspace.name
        }
        guard
            let worktree = item.primarySession?.worktreeName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !worktree.isEmpty,
            worktree.localizedCaseInsensitiveCompare(project.name) != .orderedSame
        else {
            return project.name
        }
        return "\(project.name) · \(worktree)"
    }
}
