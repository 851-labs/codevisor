import CodevisorUI
import SwiftUI

/// Matches the workspace section headers, with a disclosure chevron
/// for the collapsible archive.
struct SidebarArchivedHeader: View {
  @Binding var archivedExpanded: Bool

  var body: some View {
    HStack(spacing: 6) {
      Text("Archived")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
      // The same chevron the transcript disclosures use: its rotation is
      // scoped to Motion.indicator so it leads the content reveal rather
      // than interpolating alongside the rows shifting beneath it.
      TranscriptDisclosureChevron(expanded: archivedExpanded)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.top, 12)
    .padding(.bottom, 4)
    .contentShape(Rectangle())
    .onTapGesture { archivedExpanded.toggle() }
    .accessibilityLabel("Archived")
    .accessibilityAddTraits(.isButton)
  }
}
