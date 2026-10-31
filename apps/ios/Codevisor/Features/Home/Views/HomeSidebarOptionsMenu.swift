import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarOptionsMenu: View {
  let sections: [CustomSection]
  let actions: HomeSidebarActions
  var managesSections = true
  @ClientPreference(SidebarGrouping.preferenceKey, default: SidebarGrouping.flat) private var grouping

  var body: some View {
    Menu {
      if managesSections {
        HomeSidebarSectionsMenu(sections: sections, actions: actions)
        Divider()
      }
      Picker(selection: $grouping) {
        ForEach(SidebarGrouping.allCases, id: \.self) { option in
          Text(option.title).tag(option)
        }
      } label: {
        Label("Grouping", systemImage: "rectangle.3.group")
      }
      .pickerStyle(.menu)
      Menu {
        Section {
          ForEach(SidebarRowDetail.trailingDetails) { detail in
            toggle(detail)
          }
        }
        Section {
          ForEach(SidebarRowDetail.subtitleDetails) { detail in
            toggle(detail)
          }
        }
      } label: {
        Label("Properties", systemImage: "list.bullet")
      }
    } label: {
      Label("Sidebar Options", systemImage: "line.3.horizontal.decrease")
    }
  }

  private func toggle(_ detail: SidebarRowDetail) -> some View {
    Toggle(isOn: binding(detail)) {
      Label {
        Text(detail.title)
      } icon: {
        detail.icon
      }
    }
  }

  private func binding(_ detail: SidebarRowDetail) -> Binding<Bool> {
    Binding(
      get: { ClientPreferences.shared.isSidebarRowDetailShown(detail) },
      set: { ClientPreferences.shared.setSidebarRowDetail(detail, shown: $0) }
    )
  }
}
