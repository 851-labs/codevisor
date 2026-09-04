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
  /// Fleet context: the machines holding the project, shown as a second
  /// row. Nil (single-machine fleets) keeps the compact single-line row.
  var machineName: String? = nil

  init(
    group: ProjectGroup,
    status: HomeSessionStatus,
    showsStatus: Bool,
    machineName: String? = nil
  ) {
    self.title = group.name
    self.status = status
    self.showsStatus = showsStatus
    self.machineName = machineName
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
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.body.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
        if let machineName {
          Text(machineName)
            .font(.footnote)
            .fontWeight(.regular)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .textCase(nil)
      Spacer(minLength: 4)
    }
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .alignmentGuide(.listRowSeparatorLeading) { _ in
      Self.copyLeadingOffset
    }
  }

  private var entityIcon: some View {
    RoundedRectangle(cornerRadius: 9)
      .fill(Color(.tertiarySystemFill))
      .frame(width: Self.iconWidth, height: Self.iconWidth)
      .overlay {
        Image(systemName: symbolName)
          .font(.system(size: 20))
          .foregroundStyle(.secondary)
      }
  }
}
