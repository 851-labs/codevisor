import SwiftUI

/// Shared by the filter button and the empty-space sidebar context menu so
/// both entry points always expose the same organization and filter state.
struct SidebarFilterMenu: View {
    let organization: SidebarOrganization
    let order: SidebarOrder
    let showArchived: Binding<Bool>
    let onSetOrganization: (SidebarOrganization) -> Void
    let onSetOrder: (SidebarOrder) -> Void
    let onResetManualOrder: () -> Void

    var body: some View {
        Picker(
            "Organization",
            selection: Binding(
                get: { organization },
                set: { onSetOrganization($0) }
            )
        ) {
            ForEach(SidebarOrganization.allCases, id: \.self) { option in
                Text(option.title).tag(option)
            }
        }
        Picker(
            "Order by",
            selection: Binding(
                get: { order },
                set: { onSetOrder($0) }
            )
        ) {
            ForEach(SidebarOrder.allCases, id: \.self) { option in
                Text(option.title).tag(option)
            }
        }
        Divider()
        Toggle("Show Archived", isOn: showArchived)
        if order == .none {
            Divider()
            Button("Reset manual order") {
                onResetManualOrder()
            }
        }
    }
}
