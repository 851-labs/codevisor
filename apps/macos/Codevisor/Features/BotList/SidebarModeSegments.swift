import AppKit
import CodevisorUI
import SwiftUI

struct SidebarModeSegments: NSViewRepresentable {
  @Binding var mode: SidebarMode

  func makeCoordinator() -> Coordinator {
    Coordinator(mode: $mode)
  }

  func makeNSView(context: Context) -> ToolbarSegmentedControl {
    let control = ToolbarSegmentedControl(
      titles: SidebarMode.allCases.map(\.title), target: context.coordinator, action: #selector(Coordinator.select))
    control.setAccessibilityLabel("Sidebar Mode")
    for (segment, mode) in SidebarMode.allCases.enumerated() {
      control.setToolTip(SidebarModeShortcut.help(for: mode), forSegment: segment)
    }
    return control
  }

  func updateNSView(_ control: ToolbarSegmentedControl, context: Context) {
    context.coordinator.mode = $mode
    control.selectedSegment = SidebarMode.allCases.firstIndex(of: mode) ?? 0
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView control: ToolbarSegmentedControl, context: Context) -> CGSize?
  {
    control.fittingSize
  }

  final class Coordinator: NSObject {
    var mode: Binding<SidebarMode>

    init(mode: Binding<SidebarMode>) {
      self.mode = mode
    }

    @objc func select(_ control: NSSegmentedControl) {
      mode.wrappedValue = SidebarMode.allCases[control.selectedSegment]
    }
  }
}
