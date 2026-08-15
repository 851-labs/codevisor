import CodevisorUI
import SwiftUI

/// Matches the sidebar's projects header exactly — same font, color, and
/// padding — so "Archived" reads as a peer of the Agents/Workspaces/Projects
/// label rather than as another row in the list. The only addition is the
/// disclosure chevron, since unlike that header this one collapses.
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
