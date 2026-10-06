import SwiftUI

/// A compact heading above a run of sidebar rows: the Workspaces list, or
/// one of its groups.
struct SidebarSectionHeader<Accessory: View>: View {
  let title: String
  /// Context the title lacks, such as a project's machine.
  var subtitle: String? = nil
  @ViewBuilder var accessory: () -> Accessory

  var body: some View {
    HStack(spacing: 6) {
      // 4pt + the glyphs' side bearings lands at ~6pt of visible gap on
      // each side of the dot.
      HStack(spacing: 4) {
        Text(title)
          .truncationMode(.middle)
        if let subtitle {
          Text("·")
            .foregroundStyle(.tertiary)
          Text(subtitle)
            .foregroundStyle(.tertiary)
        }
      }
      .font(.subheadline.weight(.semibold))
      .lineLimit(1)
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isHeader)
      .help(subtitle.map { "\(title) · \($0)" } ?? title)

      Spacer(minLength: 0)

      accessory()
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .padding(.top, 12)
    .padding(.bottom, 4)
  }
}

extension SidebarSectionHeader where Accessory == EmptyView {
  init(title: String, subtitle: String? = nil) {
    self.init(title: title, subtitle: subtitle) { EmptyView() }
  }
}
