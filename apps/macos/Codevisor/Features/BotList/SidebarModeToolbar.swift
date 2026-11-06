import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarModeToolbar: ViewModifier {
  let isDrawer: Bool
  @Environment(AdaptivePanelLayout.self) private var panelLayout
  @ClientPreference(FeatureFlag.bots.preferenceKey, default: false) private var botsEnabled
  @ClientPreference(SidebarMode.preferenceKey, default: SidebarMode.code) private var storedMode
  @State private var visibleColumnWidth: CGFloat = 0
  @State private var modePickerWidth: CGFloat?

  static let minimumColumnWidth = columnWidthFitting(pickerWidth: nil, showsWindowControls: true)

  func body(content: Content) -> some View {
    content
      .background {
        if !isDrawer {
          SplitColumnExtentReader { visibleColumnWidth = $0 }.frame(width: 0, height: 0)
        }
      }
      .toolbar {
        if showsModePicker {
          ToolbarItem {
            SidebarModePicker(mode: $storedMode, help: SidebarModeShortcut.help)
              .onGeometryChange(for: CGFloat.self) {
                $0.size.width
              } action: {
                modePickerWidth = $0
              }
          }
        }
      }
  }

  private var showsModePicker: Bool {
    botsEnabled && !isDrawer && visibleColumnWidth >= widthFittingModePicker
  }

  private var widthFittingModePicker: CGFloat {
    Self.columnWidthFitting(pickerWidth: modePickerWidth, showsWindowControls: !panelLayout.isFullScreen)
  }

  private static func columnWidthFitting(pickerWidth: CGFloat?, showsWindowControls: Bool) -> CGFloat {
    let windowControls: CGFloat = 92
    let fullScreenLeadingInset: CGFloat = 6
    let fallbackPickerWidth: CGFloat = 112
    let toolbarItemPadding: CGFloat = 4
    let sidebarToggle: CGFloat = 44
    let trailingInset: CGFloat = 4
    return (showsWindowControls ? windowControls : fullScreenLeadingInset) + toolbarItemPadding
      + (pickerWidth ?? fallbackPickerWidth) + toolbarItemPadding + sidebarToggle + trailingInset
  }
}
