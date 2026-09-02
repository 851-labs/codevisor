import CodevisorCore
import SwiftUI

/// One chat row: status, harness icon, then the title over
/// "workspace · worktree". No timestamp — ordering already tells recency.
struct SessionRow: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private static let statusWidth: CGFloat = 10
  private static let statusToHarnessSpacing: CGFloat = 5
  private static let harnessWidth: CGFloat = 38
  private static let harnessToCopySpacing: CGFloat = 10
  private static let copyLeadingOffset =
    statusWidth
    + statusToHarnessSpacing
    + harnessWidth
    + harnessToCopySpacing

  let session: ChatSession
  let projectName: String?
  let harnessSymbol: String
  let status: HomeSessionStatus
  let showsContext: Bool
  /// Fleet context: the owning machine's name, shown only when more than
  /// one machine exists (nil hides it entirely).
  var machineName: String? = nil

  var body: some View {
    HStack(spacing: Self.harnessToCopySpacing) {
      HStack(spacing: Self.statusToHarnessSpacing) {
        HomeStatusIndicator(status: status)
          .frame(width: Self.statusWidth, height: Self.harnessWidth)
        harnessIcon
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(session.title.isEmpty ? "New Chat" : session.title)
          // The destination screen repeats this same truncated
          // title, so reflow here at accessibility sizes.
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        if showsContext {
          HStack(spacing: 4) {
            if let projectName {
              Text(projectName)
            }
            if let worktree = session.worktreeName, !worktree.isEmpty {
              if projectName != nil { Text("·") }
              Text(worktree)
            }
            if let machineName {
              if projectName != nil || session.worktreeName?.isEmpty == false {
                Text("·")
              }
              Text(machineName)
            }
          }
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        }
      }
      Spacer(minLength: 4)
    }
    .padding(.vertical, 3)
    // Plain buttons only hit-test their label's rendered pixels by
    // default. Fill and shape the label so the complete list-row surface
    // opens the chat, including the spacer and other empty areas.
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    // SwiftUI otherwise infers a full-width bottom separator whenever a
    // visible status dot is the row's first child. Pin every row divider
    // to the copy column; the section edge above the first row is separate.
    .alignmentGuide(.listRowSeparatorLeading) { _ in
      Self.copyLeadingOffset
    }
  }

  private var harnessIcon: some View {
    RoundedRectangle(cornerRadius: 9)
      .fill(Color(.tertiarySystemFill))
      .frame(width: Self.harnessWidth, height: Self.harnessWidth)
      .overlay {
        if session.title.isEmpty || session.title == "New Chat" {
          Image(systemName: "message.fill")
            .font(.system(size: 20))
            .foregroundStyle(.secondary)
        } else {
          HarnessIconView(
            harnessId: session.harnessId,
            fallbackSymbolName: harnessSymbol,
            size: 20
          )
          .foregroundStyle(.secondary)
        }
      }
  }
}
