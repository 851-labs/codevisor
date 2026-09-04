import CodevisorCore
import CodevisorUI
import SwiftUI

/// Native disclosure label for a project (a repository linked across
/// machines) and its direct agent children; also the "No project" row.
struct ProjectDisclosureLabel: View {
  private static let statusWidth: CGFloat = 10
  private static let statusToIconSpacing: CGFloat = 5
  private static let iconWidth: CGFloat = 38
  private static let iconToCopySpacing: CGFloat = 10
  private static let copyLeadingOffset =
    statusWidth
    + statusToIconSpacing
    + iconWidth
    + iconToCopySpacing

  let title: String
  var symbolName = EntitySystemSymbol.project
  let status: HomeSessionStatus
  let showsStatus: Bool

  init(group: ProjectGroup, status: HomeSessionStatus, showsStatus: Bool) {
    self.title = group.name
    self.status = status
    self.showsStatus = showsStatus
  }

  init(
    title: String,
    symbolName: String,
    status: HomeSessionStatus,
    showsStatus: Bool
  ) {
    self.title = title
    self.symbolName = symbolName
    self.status = status
    self.showsStatus = showsStatus
  }

  var body: some View {
    HStack(spacing: Self.iconToCopySpacing) {
      HStack(spacing: Self.statusToIconSpacing) {
        HomeStatusIndicator(status: showsStatus ? status : .idle)
          .frame(width: Self.statusWidth, height: Self.iconWidth)
        entityIcon
      }
      // One line: a linked project is one thing, and each chat beneath
      // it already names its machine.
      Text(title)
        .font(.body.weight(.semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .textCase(nil)
      Spacer(minLength: 4)
    }
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .alignmentGuide(.listRowSeparatorLeading) { _ in
      Self.copyLeadingOffset
    }
  }

  /// A bare glyph in the same slot the chat rows' tiles occupy, so the
  /// single-line row keeps its copy aligned with theirs.
  private var entityIcon: some View {
    Image(systemName: symbolName)
      .font(.system(size: 20))
      .foregroundStyle(.secondary)
      .frame(width: Self.iconWidth, height: Self.iconWidth)
  }
}
