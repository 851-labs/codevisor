import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI

/// The pinned development-build identity row naming the active worktree.
struct SidebarDevelopmentWorktreeRow: View {
  private var developmentWorktreeColor: Color {
    guard let rgba = RGBA(hex: CodevisorAppVariant.developmentIconColorHex) else { return .blue }
    return Color(rgba: rgba)
  }

  private var developmentWorktreeForegroundColor: Color {
    let foregroundHex =
      ColorMath.pickReadableForeground(
        bg: CodevisorAppVariant.developmentIconColorHex,
        candidates: ["#ffffff", "#000000"]
      ) ?? "#ffffff"
    guard let rgba = RGBA(hex: foregroundHex) else { return .white }
    return Color(rgba: rgba)
  }

  var body: some View {
    let worktreeName = CodevisorAppVariant.developmentWorktreeName
    return SidebarHeaderRow(
      title: worktreeName,
      systemImage: "ladybug.fill",
      foregroundColor: developmentWorktreeForegroundColor
    )
    .background(RoundedRectangle(cornerRadius: 6).fill(developmentWorktreeColor))
    .accessibilityLabel("Development worktree: \(worktreeName)")
    .help("Development worktree: \(worktreeName)")
  }
}
