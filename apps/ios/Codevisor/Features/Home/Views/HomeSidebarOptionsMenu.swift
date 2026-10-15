import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarOptionsMenu: View {
  @ClientPreference(SidebarGrouping.preferenceKey, default: SidebarGrouping.flat) private var grouping
  @ClientPreference(SidebarRowDetail.preferenceKey, default: SidebarRowDetail.defaults)
  private var rowDetails: [SidebarRowDetail]

  var body: some View {
    Menu {
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
      Label(detail.title, systemImage: detail.systemImage)
    }
  }

  private func binding(_ detail: SidebarRowDetail) -> Binding<Bool> {
    Binding(
      get: { rowDetails.contains(detail) },
      set: { isOn in
        rowDetails = SidebarRowDetail.allCases.filter { $0 == detail ? isOn : rowDetails.contains($0) }
      }
    )
  }
}
