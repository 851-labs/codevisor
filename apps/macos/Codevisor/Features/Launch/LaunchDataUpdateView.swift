import CodevisorCore
import CodevisorUI
import SwiftUI

struct LaunchDataUpdateView: View {
  let upgrades: LaunchUpgradeLog

  var body: some View {
    IconAnchoredStack {
      CodevisorAppIconView(size: 72)
      ProgressStepTitle(title: "Updating Codevisor")
      ProgressStepCard(steps: upgrades.entries.map(Self.step))
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Updating Codevisor")
  }

  private static func step(for upgrade: LaunchUpgradeLog.Entry) -> ProgressStep {
    ProgressStep(
      id: upgrade.id,
      title: upgrade.name,
      state: upgrade.isFinished ? .done : .running,
      details: details(for: upgrade)
    )
  }

  private static func details(for upgrade: LaunchUpgradeLog.Entry) -> [String] {
    guard !upgrade.isFinished, upgrade.total > 1 else { return [] }

    return ProgressStepDetailText.count(name: "", completed: upgrade.completed, total: upgrade.total)
  }
}
