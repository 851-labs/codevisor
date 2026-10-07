#if os(macOS)
  import Autocomplete
  import CodevisorCore
  import SwiftUI

  struct HarnessAddMenu<Icon: View>: View {
    @Binding var isPresented: Bool
    let harnesses: [HarnessFleet.CatalogEntry]
    let add: @MainActor (HarnessFleet.CatalogEntry) -> Void
    @ViewBuilder let icon: (String, String) -> Icon

    var body: some View {
      Autocomplete.Menu(isPresented: $isPresented) {
        for harness in harnesses {
          Autocomplete.Action(
            harness.name, id: harness.id,
            action: {
              isPresented = false
              add(harness)
            }
          ) {
            icon(harness.id, harness.symbolName).frame(width: 18, height: 18)
          } label: {
            Text(harness.name)
          }
        }
      } label: {
        Label("Add Harness…", systemImage: "plus")
      }
      .autocompleteSearchPrompt("Search harnesses")
      .autocompleteSearchLabel("Search harnesses")
      .autocompleteEmptyMessage("No Matching Harnesses", noItems: "All Harnesses Added")
      // Adding closes the menu itself.
      .autocompleteDismissBehavior(.never)
    }
  }
#endif
