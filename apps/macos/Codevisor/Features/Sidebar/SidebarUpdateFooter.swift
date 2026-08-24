import CodevisorCore
import CodevisorUI
import SwiftUI

/// The one ambient signal that updates exist, pinned to the sidebar's
/// bottom edge. Passive by design — no versions, no per-component detail,
/// and nothing to dismiss; clicking opens the update center. Hidden
/// entirely when everything is current.
struct SidebarUpdateFooter: View {
    var center: UpdateCenter
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        if center.availableCount > 0 || center.isUpdatingAll {
            VStack(spacing: 0) {
                Divider().overlay(theme.isSystem ? Color.clear : theme.separator)
                Button {
                    center.isPresented = true
                } label: {
                    HStack(spacing: 6) {
                        if center.isUpdatingAll {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Updating…")
                        } else {
                            Image(systemName: "arrow.down.circle")
                            Text(
                                center.availableCount == 1
                                    ? "1 update available"
                                    : "\(center.availableCount) updates available"
                            )
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .foregroundStyle(isHovered ? .primary : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .accessibilityLabel("Updates available. Opens the update center.")
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
