import AppKit
import SwiftUI

struct DrawerModePicker: NSViewRepresentable {
  @Binding var mode: SidebarMode

  func makeCoordinator() -> Coordinator {
    Coordinator(mode: $mode)
  }

  func makeNSView(context: Context) -> NSGlassEffectView {
    let control = ToolbarSegmentedControl(
      titles: SidebarMode.allCases.map(\.title), target: context.coordinator, action: #selector(Coordinator.select))
    control.setAccessibilityLabel("Sidebar Mode")
    let glass = NSGlassEffectView()
    glass.contentView = control
    glass.cornerRadius = control.fittingSize.height / 2
    return glass
  }

  func updateNSView(_ glass: NSGlassEffectView, context: Context) {
    context.coordinator.mode = $mode
    (glass.contentView as? NSSegmentedControl)?.selectedSegment = SidebarMode.allCases.firstIndex(of: mode) ?? 0
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView glass: NSGlassEffectView, context: Context) -> CGSize? {
    glass.contentView?.fittingSize
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
