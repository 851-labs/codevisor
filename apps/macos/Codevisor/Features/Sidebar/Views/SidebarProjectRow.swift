import CodevisorCore
import CodevisorUI
import SwiftUI

/// A project folder row: disclosure toggle behind the label, a hover
/// new-chat affordance, and archive/restore context actions. Archived
/// entries keep the exact same styling but swap behavior — a click offers
/// to restore instead of disclosing.
struct SidebarProjectRow: View {
    let project: Project
    var isDragPreview = false
    var isArchivedEntry = false
    let isReordering: Bool
    let isVisuallyExpanded: Bool
    let titleFont: Font
    /// Fleet context: the owning machine's name, shown as a second row.
    /// Nil (single-machine fleets) keeps the compact single-line row.
    var machineName: String? = nil
    let onDisclosureToggle: () -> Void
    let onRestoreRequest: () -> Void
    let onNewChat: () -> Void
    let onArchive: () -> Void

    var body: some View {
        HoverableRow(
            isHoverEnabled: !isReordering,
            isHoverForced: isDragPreview
        ) { isHovered in
            HStack(spacing: 6) {
                // The disclosure toggle is a real Button (not an onTapGesture):
                // buttons resolve their hit target at mouse-down, so a click on
                // the hover new-chat button can never also flip the collapse
                // state — a row-level tap gesture used to fire for those clicks.
                Button {
                    // An archived project has no chats to disclose; the click
                    // offers to bring it back instead.
                    if isArchivedEntry {
                        onRestoreRequest()
                    } else {
                        onDisclosureToggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        // On hover the project icon becomes a disclosure chevron.
                        ZStack {
                            Image(systemName: EntitySystemSymbol.project)
                                .foregroundStyle(.secondary)
                                .opacity(isHovered && !isArchivedEntry ? 0 : 1)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isVisuallyExpanded ? 90 : 0))
                                // Archived rows keep their project icon: there
                                // is no disclosure behind them to hint at.
                                .opacity(isHovered && !isArchivedEntry ? 1 : 0)
                        }
                        .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(project.name)
                                .font(titleFont)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if let machineName {
                                Text(machineName)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 6)
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Starting a chat in an archived project would resurrect it by
                // a side door, so that affordance is dropped here.
                if isHovered, !isArchivedEntry {
                    // Only open the new chat — never touch the disclosure
                    // state; the label button owns collapse/expand.
                    Button {
                        onNewChat()
                    } label: {
                        Image(systemName: "square.and.pencil").font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("New chat in \(project.name)")
                    .accessibilityLabel("New chat in \(project.name)")
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(project.folderURL.path)
        .contextMenu {
            if isArchivedEntry {
                Button {
                    onRestoreRequest()
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                        .labelStyle(.titleAndIcon)
                }
            } else {
                Button("New chat here") { onNewChat() }
                Button {
                    onArchive()
                } label: {
                    Label("Archive", systemImage: "archivebox")
                        .labelStyle(.titleAndIcon)
                }
            }
        }
    }
}
